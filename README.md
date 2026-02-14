# gmktec-mode-notify

Desktop notifications for the P-Mode hardware button on GMKtec mini PCs with
Sixunited AXB35-02 boards (EVO-X2, and similar models).

When you press the P-Mode button, a notification shows the new power profile,
CPU temperature, and fan RPM.

## Compatible Hardware

Any mini PC using the Sixunited AXB35-02 embedded controller board:

- GMKtec EVO-X2 (AMD Ryzen AI Max+ 395)
- Other GMKtec models with AXB35-02 boards
- Other OEM mini PCs with the same board (check `dmidecode -s baseboard-product-name`)

## Requirements

- **Linux** with a desktop environment supporting `org.freedesktop.Notifications`
  (GNOME, KDE, etc.)
- **[ec_su_axb35](https://github.com/cmetz/ec-su_axb35-linux)** kernel module
  (provides `/sys/class/ec_su_axb35/` sysfs interface)
- **acpid** (catches WMI events from the hardware buttons)
- **gdbus** (usually pre-installed with glib2/GNOME)

## How It Works

```
P-Mode button press
  → EC fires ACPI query _Q74
    → EC updates power mode register (0x31)
    → ACPI reprograms AMD SMU power limits via ALIB(0x0C, ...)
    → ACPI fires WMI event Notify(AMW0, 0xBC)
      → acpid catches "wmi PNP0C14:00 000000bc"
        → handler reads ec_su_axb35 sysfs for current state
          → sends desktop notification via gdbus
```

The P-Mode button cycles through three profiles:

| Mode        | TDP  | EC Register 0x31 |
| ----------- | ---- | ---------------- |
| Quiet       | 55W  | 0x02             |
| Balanced    | 85W  | 0x00             |
| Performance | 120W | 0x01             |

## Install

```bash
git clone https://github.com/alysson-souza/gmktec-mode-notify
cd gmktec-mode-notify
chmod +x install.sh
./install.sh
```

The installer:

1. Copies the handler to `/etc/acpi/gmktec-mode-notify.sh`
2. Patches `/etc/acpi/handler.sh` to route WMI events to the handler
3. Enables and starts acpid

## Uninstall

```bash
./uninstall.sh
```

## License

MIT
