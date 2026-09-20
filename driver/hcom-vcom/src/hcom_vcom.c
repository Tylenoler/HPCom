/*
 * HCOM VCOM KMDF prototype.
 *
 * A control device creates two named, buffered serial endpoints. Writes on
 * either endpoint are copied into the peer's bounded ring buffer or complete
 * a pending peer read immediately. This is intentionally self-contained: no
 * com0com code, service, DLL, or kernel component is called.
 */

#include <ntddk.h>
#include <ntddser.h>
#include <ntstrsafe.h>
#include <wdf.h>

#include "../include/hcom_vcom_public.h"

#define HCOM_VCOM_POOL_TAG 'mVcH'
#define HCOM_VCOM_MAX_PAIRS 32u
#define HCOM_VCOM_RING_BYTES (256u * 1024u)

typedef struct _HCOM_VCOM_PAIR HCOM_VCOM_PAIR, *PHCOM_VCOM_PAIR;

typedef struct _HCOM_VCOM_PORT_CONTEXT {
    PHCOM_VCOM_PAIR Pair;
    ULONG Index;
    WDFQUEUE PendingReads;
    SERIAL_BAUD_RATE BaudRate;
    SERIAL_LINE_CONTROL LineControl;
    SERIAL_HANDFLOW HandFlow;
    SERIAL_CHARS Chars;
    SERIAL_TIMEOUTS Timeouts;
} HCOM_VCOM_PORT_CONTEXT, *PHCOM_VCOM_PORT_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(HCOM_VCOM_PORT_CONTEXT, HcomPortGetContext);

struct _HCOM_VCOM_PAIR {
    WDFWAITLOCK Lock;
    WDFDEVICE Endpoint[2];
    UCHAR* Ring[2];
    SIZE_T Head[2];
    SIZE_T Tail[2];
    SIZE_T Count[2];
    WCHAR ExternalPort[HCOM_VCOM_PORT_NAME_CHARS];
    WCHAR MonitorPort[HCOM_VCOM_PORT_NAME_CHARS];
    ULONG DroppedBytes;
};

typedef struct _HCOM_VCOM_DRIVER_CONTEXT {
    WDFWAITLOCK Lock;
    WDFDEVICE ControlDevice;
    PHCOM_VCOM_PAIR Pairs[HCOM_VCOM_MAX_PAIRS];
} HCOM_VCOM_DRIVER_CONTEXT, *PHCOM_VCOM_DRIVER_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(HCOM_VCOM_DRIVER_CONTEXT, HcomDriverGetContext);

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD HcomEvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL HcomEvtControlDeviceIo;
EVT_WDF_IO_QUEUE_IO_READ HcomEvtPortRead;
EVT_WDF_IO_QUEUE_IO_WRITE HcomEvtPortWrite;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL HcomEvtPortIo;

static const UNICODE_STRING HcomControlName = RTL_CONSTANT_STRING(L"\\Device\\HcomVcomCtl");
static const UNICODE_STRING HcomControlLink = RTL_CONSTANT_STRING(L"\\DosDevices\\HcomVcomCtl");
static const UNICODE_STRING HcomControlSddl = RTL_CONSTANT_STRING(L"D:P(A;;GA;;;SY)(A;;GA;;;BA)");
static const UNICODE_STRING HcomPortSddl = RTL_CONSTANT_STRING(L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;WD)");

static NTSTATUS HcomCreateControlDevice(_In_ WDFDRIVER Driver);
static NTSTATUS HcomCreatePair(
    _In_ WDFDRIVER Driver,
    _In_ const HCOM_VCOM_CREATE_PAIR_REQUEST* Request);
static NTSTATUS HcomCreateEndpoint(
    _In_ WDFDRIVER Driver,
    _In_ PHCOM_VCOM_PAIR Pair,
    _In_ ULONG Index,
    _In_z_ PCWSTR PortName);
static VOID HcomComplete(_In_ WDFREQUEST Request, _In_ NTSTATUS Status, _In_ ULONG_PTR Information);
static BOOLEAN HcomPortNameValid(_In_reads_(HCOM_VCOM_PORT_NAME_CHARS) PCWSTR PortName);
static NTSTATUS HcomSerialIo(
    _In_ PHCOM_VCOM_PORT_CONTEXT Port,
    _In_ WDFREQUEST Request,
    _In_ ULONG IoControlCode,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength);

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDFDRIVER driver;
    NTSTATUS status;

    WDF_DRIVER_CONFIG_INIT(&config, HcomEvtDeviceAdd);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, HCOM_VCOM_DRIVER_CONTEXT);
    status = WdfDriverCreate(DriverObject, RegistryPath, &attributes, &config, &driver);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    return HcomCreateControlDevice(driver);
}

NTSTATUS
HcomEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit)
{
    UNREFERENCED_PARAMETER(Driver);
    /* The INF installs a ROOT\HCOMVCOM device only to start this KMDF
       control-plane driver. Endpoint devices are created on demand by IOCTL. */
    WdfDeviceInitFree(DeviceInit);
    return STATUS_SUCCESS;
}

static NTSTATUS
HcomCreateControlDevice(_In_ WDFDRIVER Driver)
{
    PWDFDEVICE_INIT init;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFDEVICE device;
    PHCOM_VCOM_DRIVER_CONTEXT context;
    NTSTATUS status;

    init = WdfControlDeviceInitAllocate(Driver, &HcomControlSddl);
    if (init == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    status = WdfDeviceInitAssignName(init, &HcomControlName);
    if (!NT_SUCCESS(status)) {
        WdfDeviceInitFree(init);
        return status;
    }
    WdfDeviceInitSetDeviceType(init, FILE_DEVICE_HCOM_VCOM);
    WdfDeviceInitSetIoType(init, WdfDeviceIoBuffered);
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    status = WdfDeviceCreate(&init, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    status = WdfDeviceCreateSymbolicLink(device, &HcomControlLink);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig, WdfIoQueueDispatchSequential);
    queueConfig.EvtIoDeviceControl = HcomEvtControlDeviceIo;
    status = WdfIoQueueCreate(device, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES, WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }
    context = HcomDriverGetContext(Driver);
    context->ControlDevice = device;
    status = WdfWaitLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &context->Lock);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }
    WdfControlFinishInitializing(device);
    return STATUS_SUCCESS;
}

VOID
HcomEvtControlDeviceIo(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode)
{
    WDFDEVICE device = WdfIoQueueGetDevice(Queue);
    WDFDRIVER driver = WdfDeviceGetDriver(device);
    HCOM_VCOM_CREATE_PAIR_REQUEST* createRequest;
    size_t received;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    if (IoControlCode != IOCTL_HCOM_VCOM_CREATE_PAIR) {
        HcomComplete(Request, STATUS_INVALID_DEVICE_REQUEST, 0);
        return;
    }
    if (InputBufferLength != sizeof(HCOM_VCOM_CREATE_PAIR_REQUEST)) {
        HcomComplete(Request, STATUS_INVALID_BUFFER_SIZE, 0);
        return;
    }
    status = WdfRequestRetrieveInputBuffer(
        Request,
        sizeof(HCOM_VCOM_CREATE_PAIR_REQUEST),
        (PVOID*)&createRequest,
        &received);
    if (!NT_SUCCESS(status) || received != sizeof(*createRequest)) {
        HcomComplete(Request, NT_SUCCESS(status) ? STATUS_INVALID_BUFFER_SIZE : status, 0);
        return;
    }
    if (createRequest->Version != HCOM_VCOM_PROTOCOL_VERSION ||
        !HcomPortNameValid(createRequest->ExternalPort) ||
        !HcomPortNameValid(createRequest->MonitorPort) ||
        _wcsicmp(createRequest->ExternalPort, createRequest->MonitorPort) == 0) {
        HcomComplete(Request, STATUS_INVALID_PARAMETER, 0);
        return;
    }
    status = HcomCreatePair(driver, createRequest);
    HcomComplete(Request, status, 0);
}

static NTSTATUS
HcomCreatePair(
    _In_ WDFDRIVER Driver,
    _In_ const HCOM_VCOM_CREATE_PAIR_REQUEST* Request)
{
    PHCOM_VCOM_DRIVER_CONTEXT driverContext = HcomDriverGetContext(Driver);
    PHCOM_VCOM_PAIR pair;
    ULONG index;
    NTSTATUS status;

    WdfWaitLockAcquire(driverContext->Lock, NULL);
    for (index = 0; index < HCOM_VCOM_MAX_PAIRS; ++index) {
        PHCOM_VCOM_PAIR existing = driverContext->Pairs[index];
        if (existing == NULL) {
            break;
        }
        if (_wcsicmp(existing->ExternalPort, Request->ExternalPort) == 0 ||
            _wcsicmp(existing->MonitorPort, Request->ExternalPort) == 0 ||
            _wcsicmp(existing->ExternalPort, Request->MonitorPort) == 0 ||
            _wcsicmp(existing->MonitorPort, Request->MonitorPort) == 0) {
            WdfWaitLockRelease(driverContext->Lock);
            return STATUS_OBJECT_NAME_COLLISION;
        }
    }
    if (index == HCOM_VCOM_MAX_PAIRS) {
        WdfWaitLockRelease(driverContext->Lock);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    pair = ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(*pair), HCOM_VCOM_POOL_TAG);
    if (pair == NULL) {
        WdfWaitLockRelease(driverContext->Lock);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    RtlZeroMemory(pair, sizeof(*pair));
    RtlStringCchCopyW(pair->ExternalPort, RTL_NUMBER_OF(pair->ExternalPort), Request->ExternalPort);
    RtlStringCchCopyW(pair->MonitorPort, RTL_NUMBER_OF(pair->MonitorPort), Request->MonitorPort);
    pair->Ring[0] = ExAllocatePool2(POOL_FLAG_NON_PAGED, HCOM_VCOM_RING_BYTES, HCOM_VCOM_POOL_TAG);
    pair->Ring[1] = ExAllocatePool2(POOL_FLAG_NON_PAGED, HCOM_VCOM_RING_BYTES, HCOM_VCOM_POOL_TAG);
    if (pair->Ring[0] == NULL || pair->Ring[1] == NULL) {
        if (pair->Ring[0] != NULL) ExFreePoolWithTag(pair->Ring[0], HCOM_VCOM_POOL_TAG);
        if (pair->Ring[1] != NULL) ExFreePoolWithTag(pair->Ring[1], HCOM_VCOM_POOL_TAG);
        ExFreePoolWithTag(pair, HCOM_VCOM_POOL_TAG);
        WdfWaitLockRelease(driverContext->Lock);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    status = WdfWaitLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &pair->Lock);
    if (!NT_SUCCESS(status)) {
        ExFreePoolWithTag(pair->Ring[0], HCOM_VCOM_POOL_TAG);
        ExFreePoolWithTag(pair->Ring[1], HCOM_VCOM_POOL_TAG);
        ExFreePoolWithTag(pair, HCOM_VCOM_POOL_TAG);
        WdfWaitLockRelease(driverContext->Lock);
        return status;
    }
    status = HcomCreateEndpoint(Driver, pair, 0, pair->ExternalPort);
    if (NT_SUCCESS(status)) {
        status = HcomCreateEndpoint(Driver, pair, 1, pair->MonitorPort);
    }
    if (!NT_SUCCESS(status)) {
        /* Endpoint teardown is intentionally handled by WDF at unload. Do not
           publish a partial pair to the driver list. */
        WdfWaitLockRelease(driverContext->Lock);
        return status;
    }
    driverContext->Pairs[index] = pair;
    WdfWaitLockRelease(driverContext->Lock);
    return STATUS_SUCCESS;
}

static NTSTATUS
HcomCreateEndpoint(
    _In_ WDFDRIVER Driver,
    _In_ PHCOM_VCOM_PAIR Pair,
    _In_ ULONG Index,
    _In_z_ PCWSTR PortName)
{
    WCHAR deviceNameBuffer[64];
    WCHAR linkNameBuffer[64];
    UNICODE_STRING deviceName;
    UNICODE_STRING linkName;
    PWDFDEVICE_INIT init;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDFDEVICE device;
    PHCOM_VCOM_PORT_CONTEXT context;
    NTSTATUS status;

    /* Do not use the printf family in a kernel binary: with a Desktop MSVC
       toolset it pulls the user-mode UCRT into the link. */
    status = RtlStringCchCopyW(deviceNameBuffer, RTL_NUMBER_OF(deviceNameBuffer), L"\\Device\\HcomVcom_");
    if (NT_SUCCESS(status)) {
        status = RtlStringCchCatW(deviceNameBuffer, RTL_NUMBER_OF(deviceNameBuffer), PortName);
    }
    if (!NT_SUCCESS(status)) return status;
    status = RtlStringCchCopyW(linkNameBuffer, RTL_NUMBER_OF(linkNameBuffer), L"\\DosDevices\\");
    if (NT_SUCCESS(status)) {
        status = RtlStringCchCatW(linkNameBuffer, RTL_NUMBER_OF(linkNameBuffer), PortName);
    }
    if (!NT_SUCCESS(status)) return status;
    RtlInitUnicodeString(&deviceName, deviceNameBuffer);
    RtlInitUnicodeString(&linkName, linkNameBuffer);

    init = WdfControlDeviceInitAllocate(Driver, &HcomPortSddl);
    if (init == NULL) return STATUS_INSUFFICIENT_RESOURCES;
    status = WdfDeviceInitAssignName(init, &deviceName);
    if (!NT_SUCCESS(status)) {
        WdfDeviceInitFree(init);
        return status;
    }
    WdfDeviceInitSetDeviceType(init, FILE_DEVICE_SERIAL_PORT);
    WdfDeviceInitSetIoType(init, WdfDeviceIoBuffered);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, HCOM_VCOM_PORT_CONTEXT);
    status = WdfDeviceCreate(&init, &attributes, &device);
    if (!NT_SUCCESS(status)) return status;
    status = WdfDeviceCreateSymbolicLink(device, &linkName);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }
    context = HcomPortGetContext(device);
    RtlZeroMemory(context, sizeof(*context));
    context->Pair = Pair;
    context->Index = Index;
    context->BaudRate.BaudRate = 115200;
    context->LineControl.WordLength = 8;
    context->LineControl.Parity = NO_PARITY;
    context->LineControl.StopBits = STOP_BIT_1;
    context->Chars.XonChar = 0x11;
    context->Chars.XoffChar = 0x13;

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig, WdfIoQueueDispatchParallel);
    queueConfig.EvtIoRead = HcomEvtPortRead;
    queueConfig.EvtIoWrite = HcomEvtPortWrite;
    queueConfig.EvtIoDeviceControl = HcomEvtPortIo;
    status = WdfIoQueueCreate(device, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES, WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }
    WDF_IO_QUEUE_CONFIG_INIT(&queueConfig, WdfIoQueueDispatchManual);
    status = WdfIoQueueCreate(device, &queueConfig, WDF_NO_OBJECT_ATTRIBUTES, &context->PendingReads);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(device);
        return status;
    }
    Pair->Endpoint[Index] = device;
    WdfControlFinishInitializing(device);
    return STATUS_SUCCESS;
}

VOID
HcomEvtPortRead(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t Length)
{
    PHCOM_VCOM_PORT_CONTEXT port = HcomPortGetContext(WdfIoQueueGetDevice(Queue));
    PHCOM_VCOM_PAIR pair = port->Pair;
    UCHAR* output;
    size_t outputLength;
    size_t copied = 0;
    NTSTATUS status;

    status = WdfRequestRetrieveOutputBuffer(Request, 1, (PVOID*)&output, &outputLength);
    if (!NT_SUCCESS(status)) {
        HcomComplete(Request, status, 0);
        return;
    }
    WdfWaitLockAcquire(pair->Lock, NULL);
    while (copied < Length && copied < outputLength && pair->Count[port->Index] != 0) {
        output[copied++] = pair->Ring[port->Index][pair->Head[port->Index]];
        pair->Head[port->Index] = (pair->Head[port->Index] + 1) % HCOM_VCOM_RING_BYTES;
        --pair->Count[port->Index];
    }
    WdfWaitLockRelease(pair->Lock);
    if (copied != 0) {
        HcomComplete(Request, STATUS_SUCCESS, copied);
        return;
    }
    status = WdfRequestForwardToIoQueue(Request, port->PendingReads);
    if (!NT_SUCCESS(status)) HcomComplete(Request, status, 0);
}

VOID
HcomEvtPortWrite(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t Length)
{
    PHCOM_VCOM_PORT_CONTEXT port = HcomPortGetContext(WdfIoQueueGetDevice(Queue));
    PHCOM_VCOM_PAIR pair = port->Pair;
    PHCOM_VCOM_PORT_CONTEXT peer;
    UCHAR* input;
    size_t inputLength;
    size_t accepted = 0;
    ULONG peerIndex = port->Index ^ 1u;
    WDFREQUEST pendingRead = NULL;
    NTSTATUS status;

    status = WdfRequestRetrieveInputBuffer(Request, 1, (PVOID*)&input, &inputLength);
    if (!NT_SUCCESS(status)) {
        HcomComplete(Request, status, 0);
        return;
    }
    WdfWaitLockAcquire(pair->Lock, NULL);
    peer = HcomPortGetContext(pair->Endpoint[peerIndex]);
    (void)WdfIoQueueRetrieveNextRequest(peer->PendingReads, &pendingRead);
    if (pendingRead != NULL) {
        UCHAR* output;
        size_t outputLength;
        status = WdfRequestRetrieveOutputBuffer(pendingRead, 1, (PVOID*)&output, &outputLength);
        if (NT_SUCCESS(status)) {
            accepted = min(inputLength, outputLength);
            RtlCopyMemory(output, input, accepted);
            HcomComplete(pendingRead, STATUS_SUCCESS, accepted);
        } else {
            HcomComplete(pendingRead, status, 0);
        }
    }
    while (accepted < inputLength && pair->Count[peerIndex] < HCOM_VCOM_RING_BYTES) {
        pair->Ring[peerIndex][pair->Tail[peerIndex]] = input[accepted++];
        pair->Tail[peerIndex] = (pair->Tail[peerIndex] + 1) % HCOM_VCOM_RING_BYTES;
        ++pair->Count[peerIndex];
    }
    WdfWaitLockRelease(pair->Lock);
    if (accepted == 0 && Length != 0) {
        HcomComplete(Request, STATUS_DEVICE_BUSY, 0);
        return;
    }
    HcomComplete(Request, STATUS_SUCCESS, accepted);
}

VOID
HcomEvtPortIo(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode)
{
    PHCOM_VCOM_PORT_CONTEXT port = HcomPortGetContext(WdfIoQueueGetDevice(Queue));
    HcomComplete(Request, HcomSerialIo(port, Request, IoControlCode, OutputBufferLength, InputBufferLength), 0);
}

static NTSTATUS
HcomSerialIo(
    _In_ PHCOM_VCOM_PORT_CONTEXT Port,
    _In_ WDFREQUEST Request,
    _In_ ULONG IoControlCode,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength)
{
    PVOID buffer;
    size_t length;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);
    switch (IoControlCode) {
    case IOCTL_SERIAL_SET_BAUD_RATE:
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(SERIAL_BAUD_RATE), &buffer, &length);
        if (NT_SUCCESS(status)) Port->BaudRate = *(SERIAL_BAUD_RATE*)buffer;
        return status;
    case IOCTL_SERIAL_GET_BAUD_RATE:
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(SERIAL_BAUD_RATE), &buffer, &length);
        if (NT_SUCCESS(status)) RtlCopyMemory(buffer, &Port->BaudRate, sizeof(Port->BaudRate));
        return status;
    case IOCTL_SERIAL_SET_LINE_CONTROL:
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(SERIAL_LINE_CONTROL), &buffer, &length);
        if (NT_SUCCESS(status)) Port->LineControl = *(SERIAL_LINE_CONTROL*)buffer;
        return status;
    case IOCTL_SERIAL_GET_LINE_CONTROL:
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(SERIAL_LINE_CONTROL), &buffer, &length);
        if (NT_SUCCESS(status)) RtlCopyMemory(buffer, &Port->LineControl, sizeof(Port->LineControl));
        return status;
    case IOCTL_SERIAL_SET_TIMEOUTS:
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(SERIAL_TIMEOUTS), &buffer, &length);
        if (NT_SUCCESS(status)) Port->Timeouts = *(SERIAL_TIMEOUTS*)buffer;
        return status;
    case IOCTL_SERIAL_GET_TIMEOUTS:
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(SERIAL_TIMEOUTS), &buffer, &length);
        if (NT_SUCCESS(status)) RtlCopyMemory(buffer, &Port->Timeouts, sizeof(Port->Timeouts));
        return status;
    case IOCTL_SERIAL_SET_HANDFLOW:
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(SERIAL_HANDFLOW), &buffer, &length);
        if (NT_SUCCESS(status)) Port->HandFlow = *(SERIAL_HANDFLOW*)buffer;
        return status;
    case IOCTL_SERIAL_GET_HANDFLOW:
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(SERIAL_HANDFLOW), &buffer, &length);
        if (NT_SUCCESS(status)) RtlCopyMemory(buffer, &Port->HandFlow, sizeof(Port->HandFlow));
        return status;
    case IOCTL_SERIAL_SET_CHARS:
        status = WdfRequestRetrieveInputBuffer(Request, sizeof(SERIAL_CHARS), &buffer, &length);
        if (NT_SUCCESS(status)) Port->Chars = *(SERIAL_CHARS*)buffer;
        return status;
    case IOCTL_SERIAL_GET_CHARS:
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(SERIAL_CHARS), &buffer, &length);
        if (NT_SUCCESS(status)) RtlCopyMemory(buffer, &Port->Chars, sizeof(Port->Chars));
        return status;
    case IOCTL_SERIAL_PURGE:
    case IOCTL_SERIAL_SET_DTR:
    case IOCTL_SERIAL_CLR_DTR:
    case IOCTL_SERIAL_SET_RTS:
    case IOCTL_SERIAL_CLR_RTS:
        return STATUS_SUCCESS;
    default:
        return STATUS_INVALID_DEVICE_REQUEST;
    }
}

static BOOLEAN
HcomPortNameValid(_In_reads_(HCOM_VCOM_PORT_NAME_CHARS) PCWSTR PortName)
{
    ULONG index;
    if (PortName[0] != L'C' || PortName[1] != L'O' || PortName[2] != L'M' || PortName[3] == L'\0') {
        return FALSE;
    }
    for (index = 3; index < HCOM_VCOM_PORT_NAME_CHARS; ++index) {
        if (PortName[index] == L'\0') return index > 3;
        if (PortName[index] < L'0' || PortName[index] > L'9') return FALSE;
    }
    return FALSE;
}

static VOID
HcomComplete(_In_ WDFREQUEST Request, _In_ NTSTATUS Status, _In_ ULONG_PTR Information)
{
    WdfRequestCompleteWithInformation(Request, Status, Information);
}
