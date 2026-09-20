/*
 * HCOM VCOM public control protocol.
 *
 * This header is shared conceptually by hcom-vcom.sys and Rust Core's
 * core/src/windows_vcom.rs. It deliberately contains no third-party driver
 * ABI, so HCOM owns versioning and pair lifecycle end to end.
 */

#pragma once

/* The same wire layout is consumed by user mode and KMDF.  Pulling UM's
 * winioctl.h into a kernel compilation conflicts with wdm.h definitions. */
#if defined(_NTDDK_)
#include <wdm.h>
#else
#include <winioctl.h>
#endif

#define HCOM_VCOM_PROTOCOL_VERSION 1u
#define HCOM_VCOM_PORT_NAME_CHARS 16u

/* Private device type allocated for HCOM's control device. */
#define FILE_DEVICE_HCOM_VCOM 0x8337u

#define IOCTL_HCOM_VCOM_CREATE_PAIR \
    CTL_CODE(FILE_DEVICE_HCOM_VCOM, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_HCOM_VCOM_DELETE_PAIR \
    CTL_CODE(FILE_DEVICE_HCOM_VCOM, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_HCOM_VCOM_ENUMERATE_PAIRS \
    CTL_CODE(FILE_DEVICE_HCOM_VCOM, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _HCOM_VCOM_CREATE_PAIR_REQUEST {
    ULONG Version;
    WCHAR ExternalPort[HCOM_VCOM_PORT_NAME_CHARS];
    WCHAR MonitorPort[HCOM_VCOM_PORT_NAME_CHARS];
} HCOM_VCOM_CREATE_PAIR_REQUEST, *PHCOM_VCOM_CREATE_PAIR_REQUEST;

typedef struct _HCOM_VCOM_DELETE_PAIR_REQUEST {
    ULONG Version;
    WCHAR ExternalPort[HCOM_VCOM_PORT_NAME_CHARS];
    WCHAR MonitorPort[HCOM_VCOM_PORT_NAME_CHARS];
} HCOM_VCOM_DELETE_PAIR_REQUEST, *PHCOM_VCOM_DELETE_PAIR_REQUEST;

typedef struct _HCOM_VCOM_PAIR_INFO {
    WCHAR ExternalPort[HCOM_VCOM_PORT_NAME_CHARS];
    WCHAR MonitorPort[HCOM_VCOM_PORT_NAME_CHARS];
    ULONG State;
    ULONG DroppedBytes;
} HCOM_VCOM_PAIR_INFO, *PHCOM_VCOM_PAIR_INFO;

/* Returned by ENUMERATE_PAIRS before an array of HCOM_VCOM_PAIR_INFO. */
typedef struct _HCOM_VCOM_ENUMERATE_PAIRS_RESPONSE {
    ULONG Version;
    ULONG PairCount;
} HCOM_VCOM_ENUMERATE_PAIRS_RESPONSE, *PHCOM_VCOM_ENUMERATE_PAIRS_RESPONSE;

typedef char HCOM_VCOM_CREATE_PAIR_LAYOUT_MUST_MATCH[
    sizeof(HCOM_VCOM_CREATE_PAIR_REQUEST) == 68 ? 1 : -1];
