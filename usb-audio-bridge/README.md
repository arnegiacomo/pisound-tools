# usb-audio-bridge

Play audio from a computer through the Pisound output, mixed with whatever Patchbox is already.

The Pi turns up on the computer as an ordinary USB audio device, no driver
needed, and that audio goes straight to the Pisound output. Whatever module you
have loaded only ever sees the instrument coming in the front, so it can be
MODEP, Pd, anything - as long as it runs on JACK.

```
instrument ──> Pisound in  ──> MODEP, Pd, ... ──┐
                                                ├──> Pisound out
computer   ──> USB-C       ──> UAC2Gadget     ──┘
```

I built this for practising bass guitar. The bass goes into the Pisound and MODEP
EQs it, the backing track comes from my mac, and both
exit to my headphones or amp. The pisound doesn't touch the music, and the mac's volume buttons is the 'mix knob'. This setup also allows me to aff extra effects to just the bass sound without messing with the backing track.

> [!WARNING]
> Not an officially supported Patchbox setup - two standalone systemd units
> living next to Patchbox's own services, not a Patchbox module.

## Install

From the pi:

```bash
curl -fsSL https://raw.githubusercontent.com/arnegiacomo/pisound-tools/main/usb-audio-bridge/install.sh | bash
```

Reboot when it asks. Then plug the computer into the Pi's USB-C port and pick
*Pisound USB Audio* as its output. (Add `--zita` if `alsa_in` clicks)

The same cable also carries a network link, so MOD-UI and SSH come along for
free on `http://patchbox.local` and `ssh patch@patchbox.local`, no WiFi needed. 
Set `USB_GADGET_ECM=0` to leave it out and have audio only.

> [!NOTE]
> Turn on Internet Sharing over the *Pisound USB Audio* interface (macOS: System
> Settings → General → Sharing). The Pi picks up an address from it and gets a
> route out, so `apt` works down the cable too.

> [!IMPORTANT]
> The Pi 4's only OTG-capable port is the USB-C power port, and the Pisound is
> already on the GPIO header - so the Pi ends up running off the computer, down
> a cable that has to be a real data cable. `vcgencmd get_throttled` should say
> `0x0`.

## When it doesn't work

```bash
usb-audio-gadget status
jack_lsp -c | grep usbaudio
journalctl -u usb-audio-bridge -f
```

`no USB device controller` means peripheral mode never came up - reboot, or
something is still setting `otg_mode=1`. If the computer sees nothing at all,
suspect the cable first. If `patchbox.local` won't resolve, check that the Mac
gave its *Pisound USB Audio* network interface a 169.254 address of its own.
