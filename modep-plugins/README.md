# modep-plugins

Gives MODEP the rest of the LV2 plugins Debian already ships.

MODEP only scans `/var/modep/lv2`, and its own store is thin. Every
LV2 plugin in the Debian archive installs to `/usr/lib/lv2`, where MODEP doesn't
looks. This installs a pile of them and links them across.

> [!WARNING]
> Not an officially supported way to add plugins to MODEP. It links into
> MODEP's plugin directory rather than going through its store.

## Install

From the pi:

```bash
curl -fsSL https://raw.githubusercontent.com/arnegiacomo/pisound-tools/main/modep-plugins/install.sh | bash
```

Then reload the MOD-UI page. Calf, guitarix, ZAM, x42, Invada, Rakarrack, LSP
and others should turn up.

Undo with `--remove`, which drops the symlinks and leaves the apt packages
alone. Any MODEP-store plugins will be kept.
