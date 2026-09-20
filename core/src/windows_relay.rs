//! Windows-only, overlapped-I/O relay for HCOM monitor mode.
//!
//! A monitor is a byte pump, not a protocol parser: each direction owns one
//! overlapped read and one destination writer. UI records are best-effort and
//! never decide when forwarding occurs.

use std::{
    io,
    mem::zeroed,
    os::windows::io::{FromRawHandle, IntoRawHandle},
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{SyncSender, TrySendError},
        Arc,
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use serialport::{COMPort, DataBits, FlowControl, Parity, SerialPort, StopBits};
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, GetLastError, ERROR_IO_PENDING, ERROR_OPERATION_ABORTED, GENERIC_READ,
        GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
    },
    Storage::FileSystem::{
        CreateFileW, ReadFile, WriteFile, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OVERLAPPED,
        OPEN_EXISTING,
    },
    System::{
        Threading::{
            CreateEventW, GetCurrentThread, ResetEvent, SetThreadPriority, WaitForSingleObject,
            THREAD_PRIORITY_ABOVE_NORMAL,
        },
        IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED},
    },
};

use super::{timestamp, CoreEvent, PendingRx, MAX_BATCH_BYTES};

const RELAY_BUFFER_BYTES: usize = 64 * 1024;
const UI_IDLE_BATCH: Duration = Duration::from_millis(6);

#[derive(Clone, Copy)]
pub(super) struct LinkSettings {
    pub(super) baud_rate: u32,
    pub(super) data_bits: DataBits,
    pub(super) stop_bits: StopBits,
    pub(super) parity: Parity,
    pub(super) flow_control: FlowControl,
}

/// Ownership remains with the session until both workers have stopped. This
/// lets close_port cancel outstanding kernel operations before joining.
pub(super) struct NativeMonitorSession {
    pub(super) virtual_port: String,
    stop: Arc<AtomicBool>,
    physical: Arc<OverlappedPort>,
    virtual_endpoint: Arc<OverlappedPort>,
    physical_to_virtual: JoinHandle<()>,
    virtual_to_physical: JoinHandle<()>,
}

impl NativeMonitorSession {
    pub(super) fn close(self) {
        self.stop.store(true, Ordering::Relaxed);
        self.physical.cancel_all();
        self.virtual_endpoint.cancel_all();
        let _ = self.physical_to_virtual.join();
        let _ = self.virtual_to_physical.join();
    }
}

pub(super) fn open(
    physical_port: &str,
    virtual_port: &str,
    settings: LinkSettings,
    session: u64,
    sender: SyncSender<CoreEvent>,
) -> Result<NativeMonitorSession, String> {
    let physical = Arc::new(OverlappedPort::open(physical_port, settings)?);
    let virtual_endpoint = match OverlappedPort::open(virtual_port, settings) {
        Ok(port) => Arc::new(port),
        Err(error) => return Err(error),
    };
    let stop = Arc::new(AtomicBool::new(false));
    let physical_to_virtual = spawn_worker(
        Arc::clone(&physical),
        Arc::clone(&virtual_endpoint),
        RelayDirection::Rx,
        session,
        Arc::clone(&stop),
        sender.clone(),
    );
    let virtual_to_physical = spawn_worker(
        Arc::clone(&virtual_endpoint),
        Arc::clone(&physical),
        RelayDirection::Tx,
        session,
        Arc::clone(&stop),
        sender,
    );
    Ok(NativeMonitorSession {
        virtual_port: virtual_port.to_owned(),
        stop,
        physical,
        virtual_endpoint,
        physical_to_virtual,
        virtual_to_physical,
    })
}

#[derive(Clone, Copy)]
enum RelayDirection {
    Rx,
    Tx,
}

fn spawn_worker(
    source: Arc<OverlappedPort>,
    destination: Arc<OverlappedPort>,
    direction: RelayDirection,
    session: u64,
    stop: Arc<AtomicBool>,
    sender: SyncSender<CoreEvent>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        // Above-normal is enough to reduce scheduler jitter without starving
        // UI, storage, or the USB stack. Never use realtime priority here.
        unsafe {
            let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
        }
        let mut buffer = vec![0_u8; RELAY_BUFFER_BYTES];
        let mut reader = OverlappedReader::new(Arc::clone(&source));
        let mut display = PendingRx::with_capacity(MAX_BATCH_BYTES);
        let mut dropped_bytes = 0_u64;
        let mut dropped_burst_bytes = 0_u64;

        while !stop.load(Ordering::Relaxed) {
            match reader.poll(&mut buffer, UI_IDLE_BATCH) {
                Ok(PollResult::Idle) => {
                    if !publish_display(
                        direction,
                        session,
                        &mut display,
                        &mut dropped_bytes,
                        &mut dropped_burst_bytes,
                        &sender,
                    ) {
                        break;
                    }
                }
                Ok(PollResult::Data(count)) => {
                    // This is the whole transport hot path: fixed buffer,
                    // overlapped read, overlapped write. No HEX conversion,
                    // disk I/O, UI work, or flush is performed here.
                    if let Err(error) = destination.write_all(&buffer[..count], &stop) {
                        send_fault(
                            &sender,
                            direction,
                            session,
                            format!("旁路转发写入失败：{error}"),
                        );
                        break;
                    }
                    display.append(&buffer[..count], timestamp());
                    if display.bytes.len() >= MAX_BATCH_BYTES
                        && !publish_display(
                            direction,
                            session,
                            &mut display,
                            &mut dropped_bytes,
                            &mut dropped_burst_bytes,
                            &sender,
                        )
                    {
                        break;
                    }
                }
                Err(_error) if stop.load(Ordering::Relaxed) => break,
                Err(error) => {
                    send_fault(
                        &sender,
                        direction,
                        session,
                        format!("旁路读取失败：{error}"),
                    );
                    break;
                }
            }
        }
    })
}

fn send_fault(
    sender: &SyncSender<CoreEvent>,
    direction: RelayDirection,
    session: u64,
    message: String,
) {
    let event = match direction {
        RelayDirection::Rx => CoreEvent::SerialFault { session, message },
        RelayDirection::Tx => CoreEvent::MonitorFault { session, message },
    };
    let _ = sender.send(event);
}

fn publish_display(
    direction: RelayDirection,
    session: u64,
    display: &mut PendingRx,
    dropped_bytes: &mut u64,
    dropped_burst_bytes: &mut u64,
    sender: &SyncSender<CoreEvent>,
) -> bool {
    let Some((bytes, timestamp)) = display.take() else {
        return true;
    };
    let event = match direction {
        RelayDirection::Rx => CoreEvent::SerialData {
            session,
            bytes,
            timestamp,
            dropped_bytes: *dropped_bytes,
            dropped_burst_bytes: *dropped_burst_bytes,
        },
        RelayDirection::Tx => CoreEvent::MonitorData {
            session,
            bytes,
            timestamp,
            dropped_bytes: *dropped_bytes,
            dropped_burst_bytes: *dropped_burst_bytes,
        },
    };
    match sender.try_send(event) {
        Ok(()) => {
            *dropped_burst_bytes = 0;
            true
        }
        Err(TrySendError::Full(CoreEvent::SerialData { bytes, .. }))
        | Err(TrySendError::Full(CoreEvent::MonitorData { bytes, .. })) => {
            *dropped_bytes += bytes.len() as u64;
            *dropped_burst_bytes += bytes.len() as u64;
            true
        }
        Err(TrySendError::Disconnected(_)) => false,
        Err(TrySendError::Full(_)) => unreachable!("relay worker only sends display data"),
    }
}

/// A handle opened with FILE_FLAG_OVERLAPPED. One worker reads from a handle
/// while the other direction writes to it, so each operation class has exactly
/// one owner and needs no hot-path mutex.
struct OverlappedPort {
    handle: HANDLE,
}

unsafe impl Send for OverlappedPort {}
unsafe impl Sync for OverlappedPort {}

impl OverlappedPort {
    fn open(name: &str, settings: LinkSettings) -> Result<Self, String> {
        let mut path: Vec<u16> = r"\\.\".encode_utf16().collect();
        path.extend(name.encode_utf16());
        path.push(0);
        let handle = unsafe {
            CreateFileW(
                path.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                ptr::null(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                0,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(format!("无法打开 {name}：{}", io::Error::last_os_error()));
        }

        // Reuse serialport's DCB configuration, then reclaim the handle for
        // native overlapped ReadFile/WriteFile. into_raw_handle prevents the
        // temporary COMPort from closing it.
        let mut port = unsafe { COMPort::from_raw_handle(handle as _) };
        let configured = port
            .set_baud_rate(settings.baud_rate)
            .and_then(|_| port.set_data_bits(settings.data_bits))
            .and_then(|_| port.set_stop_bits(settings.stop_bits))
            .and_then(|_| port.set_parity(settings.parity))
            .and_then(|_| port.set_flow_control(settings.flow_control));
        if let Err(error) = configured {
            return Err(format!("无法配置 {name}：{error}"));
        }
        let handle = port.into_raw_handle() as HANDLE;
        Ok(Self { handle })
    }

    fn cancel_all(&self) {
        unsafe {
            let _ = CancelIoEx(self.handle, ptr::null());
        }
    }

    fn write_all(&self, bytes: &[u8], stop: &AtomicBool) -> io::Result<()> {
        let mut offset = 0;
        while offset < bytes.len() {
            if stop.load(Ordering::Relaxed) {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "relay stopped"));
            }
            let written = self.write_once(&bytes[offset..], stop)?;
            if written == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "serial write returned zero",
                ));
            }
            offset += written;
        }
        Ok(())
    }

    fn write_once(&self, bytes: &[u8], stop: &AtomicBool) -> io::Result<usize> {
        unsafe {
            let event = CreateEventW(ptr::null(), 1, 0, ptr::null());
            if event == 0 {
                return Err(io::Error::last_os_error());
            }
            let mut overlapped: OVERLAPPED = zeroed();
            overlapped.hEvent = event;
            let mut count = 0_u32;
            let ok = WriteFile(
                self.handle,
                bytes.as_ptr(),
                bytes.len().min(u32::MAX as usize) as u32,
                &mut count,
                &mut overlapped,
            );
            if ok != 0 {
                CloseHandle(event);
                return Ok(count as usize);
            }
            if GetLastError() != ERROR_IO_PENDING {
                let error = io::Error::last_os_error();
                CloseHandle(event);
                return Err(error);
            }
            let result = wait_for_operation(self.handle, &mut overlapped, event, stop, &mut count);
            CloseHandle(event);
            result.map(|_| count as usize)
        }
    }
}

impl Drop for OverlappedPort {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.handle);
        }
    }
}

struct OverlappedReader {
    port: Arc<OverlappedPort>,
    event: HANDLE,
    overlapped: OVERLAPPED,
    pending: bool,
}

enum PollResult {
    Data(usize),
    Idle,
}

impl OverlappedReader {
    fn new(port: Arc<OverlappedPort>) -> Self {
        let event = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
        Self {
            port,
            event,
            overlapped: unsafe { zeroed() },
            pending: false,
        }
    }

    fn poll(&mut self, buffer: &mut [u8], idle: Duration) -> io::Result<PollResult> {
        if self.event == 0 {
            return Err(io::Error::last_os_error());
        }
        unsafe {
            if !self.pending {
                let _ = ResetEvent(self.event);
                self.overlapped = zeroed();
                self.overlapped.hEvent = self.event;
                let mut count = 0_u32;
                let ok = ReadFile(
                    self.port.handle,
                    buffer.as_mut_ptr(),
                    buffer.len().min(u32::MAX as usize) as u32,
                    &mut count,
                    &mut self.overlapped,
                );
                if ok != 0 {
                    return Ok(PollResult::Data(count as usize));
                }
                if GetLastError() != ERROR_IO_PENDING {
                    return Err(io::Error::last_os_error());
                }
                self.pending = true;
            }
            match WaitForSingleObject(self.event, idle.as_millis().max(1) as u32) {
                WAIT_OBJECT_0 => {
                    let mut count = 0_u32;
                    let ok = GetOverlappedResult(self.port.handle, &self.overlapped, &mut count, 0);
                    self.pending = false;
                    if ok == 0 {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(PollResult::Data(count as usize))
                }
                WAIT_TIMEOUT => Ok(PollResult::Idle),
                _ => Err(io::Error::last_os_error()),
            }
        }
    }
}

impl Drop for OverlappedReader {
    fn drop(&mut self) {
        if self.event != 0 {
            unsafe {
                if self.pending {
                    let _ = CancelIoEx(self.port.handle, &self.overlapped);
                }
                CloseHandle(self.event);
            }
        }
    }
}

unsafe fn wait_for_operation(
    handle: HANDLE,
    overlapped: &mut OVERLAPPED,
    event: HANDLE,
    stop: &AtomicBool,
    count: &mut u32,
) -> io::Result<()> {
    loop {
        match WaitForSingleObject(event, 50) {
            WAIT_OBJECT_0 => {
                if GetOverlappedResult(handle, overlapped, count, 0) != 0 {
                    return Ok(());
                }
                let error = io::Error::last_os_error();
                if GetLastError() == ERROR_OPERATION_ABORTED && stop.load(Ordering::Relaxed) {
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "relay stopped"));
                }
                return Err(error);
            }
            WAIT_TIMEOUT if stop.load(Ordering::Relaxed) => {
                let _ = CancelIoEx(handle, overlapped);
            }
            WAIT_TIMEOUT => {}
            _ => return Err(io::Error::last_os_error()),
        }
    }
}
