# HCOM Core IPC v2 — NDJSON over stdio

Phase 2 implements the Windows UART core behind the Phase 1 process boundary. Flutter launches `hcom-core` as a child process and exchanges one UTF-8 JSON object per line. `stdout` is reserved for protocol events; human diagnostics must go to `stderr`.

## Commands: Flutter → Rust

```json
{"command":"hello","payload":{"client":"flutter","protocolVersion":2}}
{"command":"ping","payload":{}}
{"command":"scan_ports","payload":{}}
{"command":"open_port","payload":{"port":"COM3","baudRate":115200,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none"}}
{"command":"create_virtual_pair","payload":{"externalPort":"COM50","monitorPort":"COM51"}}
{"command":"open_monitor","payload":{"port":"COM3","virtualPort":"COM51","baudRate":115200,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none"}}
{"command":"close_port","payload":{}}
{"command":"write_data","payload":{"bytes":"AA 55 01 00"}}
{"command":"start_periodic","payload":{"intervalMs":1000,"commands":["AA 55 01 00","AA 55 02 00"]}}
{"command":"stop_periodic","payload":{}}
```

`open_port` maps the selected settings to the native Windows COM handle. The Core accepts `none` / `odd` / `even` parity and `none` / `rts_cts` / `xon_xoff` flow control. The Flutter client must wait for `connection_state: connected` before allowing `write_data`.

`start_periodic` starts a dedicated Rust scheduling thread, which sends all listed HEX commands immediately and then at the requested interval. `stop_periodic`, closing the port, or a write failure stops and joins that worker. Flutter must not enqueue every cycle as independent `write_data` commands.

`create_virtual_pair` calls the HCOM-owned `hcom-vcom.sys` control device at `\\.\HcomVcomCtl` with a versioned private IOCTL. The formal HCOM installer deploys the Microsoft-signed HCOM VCOM package before Core is launched; the Core neither shells out to nor searches for com0com or another third-party tool. Creating a kernel virtual serial device may require the system's administrator approval during installation. A release without the signed HCOM driver payload is deliberately reported as incomplete rather than asking end users to search for third-party software.

`open_monitor` opens the physical `port` and HCOM's endpoint of a virtual pair (`virtualPort`) with Windows overlapped I/O. Its physical-to-virtual and virtual-to-physical workers are independent, use fixed 64KiB buffers, and never call `FlushFileBuffers` in the forwarding path. Bytes from the external software are forwarded to the physical port and reported as TX; bytes received from the physical port are reported as RX and forwarded back to the virtual endpoint. Display batches remain best-effort and bounded, so UI/log pressure cannot delay the forwarding decision. `write_data` and `start_periodic` are rejected while this mode is active, ensuring HCOM remains a relay rather than a second writer.

## Events: Rust → Flutter

```json
{"event":"ready","payload":{"protocolVersion":2,"coreVersion":"0.3.0"}}
{"event":"pong","payload":{}}
{"event":"ports","payload":{"ports":[{"port":"COM3","description":"USB Serial Device","hardwareId":"USB\\VID_1A86&PID_7523","kind":"usb"}]}}
{"event":"serial_data","payload":{"direction":"rx","timestamp":"2026-09-10T12:00:00.000Z","bytes":"AA 55","droppedBytes":0,"droppedBurstBytes":0}}
{"event":"connection_state","payload":{"state":"connecting|connected|error|disconnected","port":"COM3"}}
{"event":"periodic_state","payload":{"active":true}}
{"event":"virtual_pair","payload":{"externalPort":"COM50","monitorPort":"COM51"}}
{"event":"monitor_state","payload":{"active":true,"virtualPort":"COM51"}}
{"event":"error","payload":{"code":"unsupported","message":"..."}}
```

Messages are independently parseable and ordered on the child-process stream. UART is a byte stream, so the Core coalesces short reads and submits a display batch after 6ms of RX idle time (or on reaching 4KiB); this is a display boundary, not a protocol frame or relay delay. Flutter applies a deterministic fixed-size, delimiter, or template-derived length-field rule; it never learns a frame size from operating-system read boundaries. RX and relayed TX use a bounded queue of 512 display events and never block the serial reader or relay path. When the consumer cannot keep up, newest display batches may be discarded: `droppedBytes` is the monotonic session total and `droppedBurstBytes` is the amount since the last delivered display event. Both are emitted in `serial_data`, and a `backpressure` error makes the loss visible. Closing stdin is a graceful Core shutdown: it closes the port and joins workers before exit. Single writes are capped at 16KiB.
