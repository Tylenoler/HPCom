/*
 * HCOM VCOM installer helper.
 *
 * This program is invoked by the elevated HCOM installer, not by the user.
 * It creates the root-enumerated bus device with Windows SetupAPI and applies
 * the package INF.  It intentionally has no devcon, pnputil, or third-party
 * runtime dependency.
 */

#include <windows.h>
#include <newdev.h>
#include <setupapi.h>
#include <stdio.h>
#include <wchar.h>

#pragma comment(lib, "newdev.lib")
#pragma comment(lib, "setupapi.lib")

static const GUID HcomPortsClassGuid = {
    0x4d36e978, 0xe325, 0x11ce, {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}
};
static const WCHAR HcomHardwareId[] = L"ROOT\\HCOMVCOM";

static BOOL
HcomDeviceExists(void)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA deviceInfo;
    DWORD index;
    BOOL exists = FALSE;

    devices = SetupDiGetClassDevsW(&HcomPortsClassGuid, NULL, NULL, DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    for (index = 0; ; ++index) {
        WCHAR hardwareIds[512];
        DWORD required = 0;
        WCHAR* value;
        deviceInfo.cbSize = sizeof(deviceInfo);
        if (!SetupDiEnumDeviceInfo(devices, index, &deviceInfo)) {
            break;
        }
        if (!SetupDiGetDeviceRegistryPropertyW(
                devices,
                &deviceInfo,
                SPDRP_HARDWAREID,
                NULL,
                (PBYTE)hardwareIds,
                sizeof(hardwareIds),
                &required)) {
            continue;
        }
        for (value = hardwareIds; *value != L'\0'; value += wcslen(value) + 1) {
            if (_wcsicmp(value, HcomHardwareId) == 0) {
                exists = TRUE;
                break;
            }
        }
        if (exists) {
            break;
        }
    }
    SetupDiDestroyDeviceInfoList(devices);
    return exists;
}

static BOOL
HcomRegisterRootDevice(void)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA deviceInfo;
    WCHAR hardwareIds[] = L"ROOT\\HCOMVCOM\0\0";
    BOOL result = FALSE;

    devices = SetupDiCreateDeviceInfoList(&HcomPortsClassGuid, NULL);
    if (devices == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    deviceInfo.cbSize = sizeof(deviceInfo);
    if (!SetupDiCreateDeviceInfoW(
            devices,
            L"HCOM Virtual COM Bus",
            &HcomPortsClassGuid,
            NULL,
            NULL,
            DICD_GENERATE_ID,
            &deviceInfo)) {
        goto cleanup;
    }
    if (!SetupDiSetDeviceRegistryPropertyW(
            devices,
            &deviceInfo,
            SPDRP_HARDWAREID,
            (const BYTE*)hardwareIds,
            sizeof(hardwareIds))) {
        goto cleanup;
    }
    if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, devices, &deviceInfo)) {
        goto cleanup;
    }
    result = TRUE;

cleanup:
    SetupDiDestroyDeviceInfoList(devices);
    return result;
}

int __cdecl
wmain(int argc, wchar_t** argv)
{
    WCHAR infPath[MAX_PATH];
    BOOL rebootRequired = FALSE;

    if (argc != 3 || _wcsicmp(argv[1], L"install") != 0) {
        fwprintf(stderr, L"Usage: hcom-vcom-installer.exe install <signed-driver-package-directory>\n");
        return 64;
    }
    if (swprintf_s(infPath, ARRAYSIZE(infPath), L"%s\\hcom-vcom.inf", argv[2]) < 0) {
        fwprintf(stderr, L"Driver package path is too long.\n");
        return 64;
    }
    if (GetFileAttributesW(infPath) == INVALID_FILE_ATTRIBUTES) {
        fwprintf(stderr, L"HCOM VCOM INF was not found: %s\n", infPath);
        return 66;
    }
    if (!HcomDeviceExists() && !HcomRegisterRootDevice()) {
        fwprintf(stderr, L"Could not register ROOT\\HCOMVCOM (error %lu). Run from the elevated HCOM installer.\n", GetLastError());
        return 1;
    }
    if (!UpdateDriverForPlugAndPlayDevicesW(
            NULL,
            HcomHardwareId,
            infPath,
            INSTALLFLAG_FORCE,
            &rebootRequired)) {
        fwprintf(stderr, L"Could not apply HCOM VCOM driver package (error %lu).\n", GetLastError());
        return 1;
    }
    wprintf(L"HCOM VCOM installed%s.\n", rebootRequired ? L"; restart required" : L"");
    return rebootRequired ? 3010 : 0;
}
