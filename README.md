# P-touch Bridge

A background service that makes Brother P-touch Bluetooth printers available in the macOS Print dialog. Requires macOS 26 or later.

## Usage

Install the package, pair the printer in Bluetooth settings, and allow Bluetooth access when prompted. The service reads the loaded cassette and adds recognised printers automatically. The default paper width follows the loaded cassette; custom sizes set the label length. Reopen the Print dialog after changing cassettes.

Print multiple labels as one multi-page job to share the initial tape feed. Each page is cut separately.

A LaunchAgent starts the service at sign-in. It checks paired printers every ten seconds while idle and reconnects automatically when they return. Print Center reports connection and printer errors. Jobs waiting for a printer proceed when it is ready. Interrupted or rejected jobs stay stopped: check the printed labels, cancel the job, correct the problem and print again. Reconnecting does not retry an interrupted job.

## Compatibility

| Printer profile               | Cassette widths                 | Hardware tested      |
| ----------------------------- | ------------------------------- | -------------------- |
| PT-P710BT (P-touch Cube Plus) | 3.5, 6, 9, 12, 18 and 24 mm TZe | Bluetooth, 24 mm TZe |

Other widths use Brother's documented geometry. Additional models need a printer profile and hardware testing.

## Development

Open `PTouchBridge.xcodeproj` in Xcode. The shared `PTouchBridge` scheme owns building, debugging and testing. CI uses the Mise tasks:

```sh
mise run fmt-check
mise run lint
mise run test
mise run build
```

The service accepts PDFs over local IPP, renders them with Core Graphics, and sends Brother raster commands through IOBluetooth. Printer profiles define resolution, cassette geometry and length limits.

PAPPL 1.4.12 was evaluated as the owner of IPP and jobs. It builds on macOS, supports loopback listeners and custom devices, and can dispatch printing work to the helper's main run loop. A failed print callback ends the job as aborted without replay. Bluetooth access would still belong to the signed user-session helper.

PAPPL is not used because its required raster path conflicts with rejecting unsuitable documents before printing. It requires raster callbacks even for a PDF driver. In a synthetic bi-level driver test, its raster conversion reduced a 256-pixel page to the configured 170 pixels before the callbacks, discarded all ink outside that width and completed the job. The driver cannot validate content it never receives. Adopting it would require a separate raster preflight path or an upstream change; supplying dummy callbacks or advertising unsupported formats would hide the problem. See [PAPPL's driver requirements](https://github.com/michaelrsweet/pappl/blob/v1.4.12/pappl/printer-driver.c) and [raster processing](https://github.com/michaelrsweet/pappl/blob/v1.4.12/pappl/job-process.c).

## Distribution

Release Please manages versions. CI builds, signs and notarizes the installer, which places the helper in `/Library/Application Support/P-touch Bridge` and its LaunchAgent in `/Library/LaunchAgents`.

## License

[Apache License 2.0](LICENSE). MIT-licensed raster encoding is attributed in [THIRD-PARTY-NOTICES.txt](PTouchBridge/THIRD-PARTY-NOTICES.txt).

Protocol reference: [Brother raster commands](https://download.brother.com/welcome/docp100064/cv_pte550wp750wp710bt_eng_raster_102.pdf).
