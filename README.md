# P-touch macOS Bridge

A background service that makes Brother P-touch Bluetooth printers available in the macOS Print dialog. Requires macOS 26 or later.

## Usage

Install the package, pair the printer in Bluetooth settings, and allow Bluetooth access when prompted. The service adds recognised printers automatically. Choose the printer and a paper size matching the loaded cassette in the Print dialog.

A LaunchAgent starts the service at sign-in. Manage print jobs in Print Center.

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

## Distribution

Release Please manages versions. CI builds, signs and notarizes the installer, which places the helper in `/Library/Application Support/P-touch Bridge` and its LaunchAgent in `/Library/LaunchAgents`.

## License

[Apache License 2.0](LICENSE). MIT-licensed raster encoding is attributed in [THIRD-PARTY-NOTICES.txt](PTouchBridge/THIRD-PARTY-NOTICES.txt).

Protocol reference: [Brother raster commands](https://download.brother.com/welcome/docp100064/cv_pte550wp750wp710bt_eng_raster_102.pdf).
