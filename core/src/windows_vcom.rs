//! HCOM-owned virtual-COM control client.
//!
//! This module deliberately talks to `hcom-vcom.sys` directly instead of
//! shelling out to a third-party virtual-port utility. The driver owns the
//! kernel objects and the pair lifecycle; the Rust Core only requests a pair.

use std::{io, mem::size_of, ptr};

use windows_sys::Win32::{
    Foundation::{CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE},
    Storage::FileSystem::{CreateFileW, FILE_ATTRIBUTE_NORMAL, OPEN_EXISTING},
    System::IO::DeviceIoControl,
};

const CONTROL_PATH: &str = r"\\.\HcomVcomCtl";
const PORT_NAME_CHARS: usize = 16;
const PROTOCOL_VERSION: u32 = 1;

// Keep these values byte-for-byte aligned with drivers/hcom-vcom/include/
// hcom_vcom_public.h. Function values remain in HCOM's private range.
const FILE_DEVICE_HCOM_VCOM: u32 = 0x8337;
const METHOD_BUFFERED: u32 = 0;
const FILE_ANY_ACCESS: u32 = 0;
const fn ctl_code(function: u32) -> u32 {
    (FILE_DEVICE_HCOM_VCOM << 16) | (FILE_ANY_ACCESS << 14) | (function << 2) | METHOD_BUFFERED
}
const IOCTL_HCOM_VCOM_CREATE_PAIR: u32 = ctl_code(0x800);

#[repr(C)]
struct CreatePairRequest {
    version: u32,
    external_port: [u16; PORT_NAME_CHARS],
    monitor_port: [u16; PORT_NAME_CHARS],
}

pub(super) fn create_pair(external_port: &str, monitor_port: &str) -> Result<(), String> {
    let handle = open_control_device()?;
    let request = CreatePairRequest {
        version: PROTOCOL_VERSION,
        external_port: utf16_port_name(external_port)?,
        monitor_port: utf16_port_name(monitor_port)?,
    };
    let mut returned = 0_u32;
    let ok = unsafe {
        DeviceIoControl(
            handle,
            IOCTL_HCOM_VCOM_CREATE_PAIR,
            &request as *const CreatePairRequest as _,
            size_of::<CreatePairRequest>() as u32,
            ptr::null_mut(),
            0,
            &mut returned,
            ptr::null_mut(),
        )
    };
    unsafe {
        CloseHandle(handle);
    }
    if ok == 0 {
        return Err(format!(
            "HPCOM 虚拟串口驱动无法创建端口对：{}",
            io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn open_control_device() -> Result<HANDLE, String> {
    let mut path: Vec<u16> = CONTROL_PATH.encode_utf16().collect();
    path.push(0);
    let handle = unsafe {
        CreateFileW(
            path.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            ptr::null(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            0,
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(format!(
            "HPCOM 虚拟串口驱动未安装或未启动。请使用包含 HPCOM VCOM 驱动的正式安装包：{}",
            io::Error::last_os_error()
        ));
    }
    Ok(handle)
}

fn utf16_port_name(value: &str) -> Result<[u16; PORT_NAME_CHARS], String> {
    let units: Vec<u16> = value.encode_utf16().collect();
    if units.len() >= PORT_NAME_CHARS {
        return Err("虚拟端口名称过长。".to_owned());
    }
    let mut out = [0_u16; PORT_NAME_CHARS];
    out[..units.len()].copy_from_slice(&units);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_pair_port_names_null_terminated() {
        let value = utf16_port_name("COM123").expect("valid port name");
        assert_eq!(
            &value[..7],
            &[
                b'C' as u16,
                b'O' as u16,
                b'M' as u16,
                b'1' as u16,
                b'2' as u16,
                b'3' as u16,
                0
            ]
        );
    }
}
