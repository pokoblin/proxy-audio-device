## Proxy Audio Driver

A HAL virtual audio driver for macOS that sends all output to another audio device. Its main purpose is to make it possible to use macOS's system volume controls, such as the volume menu bar icon or volume keyboard keys, to change the volume of external audio interfaces that don't allow it. It might be useful for something else, too.

This is a fork of [briankendall/proxy-audio-device](https://github.com/briankendall/proxy-audio-device); credit for the original driver and Settings app belongs to Brian Kendall. See "Changes in this fork" below for the deltas this branch carries over upstream.

### Changes in this fork

- **Fix: audio resumes automatically after macOS sleep/wake.** Previously the proxy device went silent after wake until you manually toggled the system output device. The driver now hooks IOKit power notifications (`IORegisterForSystemPower`) and rebuilds its IOProc on wake.
- **Install / uninstall scripts.** `install.sh` and `uninstall.sh` (shipped in the release zip) install or remove the pre-built bundles in one command. `rebuild-and-install.sh` (in the repo) builds from source with your own signing identity — config lives in a gitignored `rebuild-and-install.config`, so your team ID never enters version control. All three restart coreaudiod with a SIP-aware fallback for macOS 26+.

### Installation

All install paths below restart coreaudiod with a SIP-aware fallback (`launchctl kickstart` → `sudo killall coreaudiod`), so they work on macOS 14.4+ and macOS 26+ alike.

#### Pre-built zip from Releases (recommended)

Grab the latest zip from the [Releases page](https://github.com/pokoblin/proxy-audio-device/releases). It ships pre-built signed bundles plus `install.sh` / `uninstall.sh`. After unzipping:

```bash
cd ProxyAudioDevice_v1.0.8
./install.sh                  # install driver + Settings.app, restart coreaudiod
# or: ./install.sh --no-app   # driver only
# or: ./install.sh --dry-run  # preview without changing anything
```

To remove later:

```bash
./uninstall.sh                # remove driver only
./uninstall.sh --app          # also remove Settings.app from /Applications
./uninstall.sh --dry-run      # preview without changing anything
```

No build tools or signing identity required.

#### Build from source

If you want to build and install from a local clone — for development, or because you want to sign with your own identity — use `rebuild-and-install.sh` at the repo root:

```bash
cp rebuild-and-install.config.template rebuild-and-install.config
$EDITOR rebuild-and-install.config        # fill in DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY
./rebuild-and-install.sh
```

List available signing identities with `security find-identity -v -p codesigning`. The config file is gitignored, so your team ID never gets committed. Other flags: `--build` (skip install), `--no-clean` (incremental).

After installation, drag `Proxy Audio Device Settings.app` (built under `build/Release/`) into `/Applications` and launch it to configure the device. `./uninstall.sh` (same flags as above) removes things when you're done.

#### Manual installation

1. Download the latest release from this GitHub repository

2. Create the directory `HAL` if it does not exist. Open a terminal window, execute the following command and enter your administrator password when prompted:

        sudo mkdir /Library/Audio/Plug-Ins/HAL

3. Move the directory `ProxyAudioDriver.driver` to `/Library/Audio/Plug-Ins/HAL` and assign it the correct owner. Execute in the root directory of the unzipped file:

        sudo mv ./ProxyAudioDevice.driver /Library/Audio/Plug-Ins/HAL/
        sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver

4. Either reboot your system or reboot Core Audio by executing the following command:

        # macOS <= 13
        sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
   
        # macOS >= 14.4
        sudo killall coreaudiod

6. Run Proxy Audio Device Settings to configure the proxy output device's name, which output device the driver will proxy to, and how large you want its audio buffer to be.

#### Manual uninstallation

1. Open a terminal window and execute the following command:

        sudo rm -rf /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver

2. Either reboot your system or reboot Core Audio by executing the following command:

        # macOS <= 13
        sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
   
        # macOS >= 14.4
        sudo killall coreaudiod

### Building

For end users the [pre-built zip](#pre-built-zip-from-releases-recommended) is the simplest path. To build from source, use `./rebuild-and-install.sh` (see [Build from source](#build-from-source)) — or open the Xcode project, build the `ProxyAudioDevice` and `Proxy Audio Device Settings` targets manually, and follow the [manual installation](#manual-installation) steps.


### Issues

If you make the audio buffer too small then the driver will introduce pops, crackles, or distortion. If you notice that then try increasing the buffer size.


### Possible Future Work

- Indicator in the settings app for when the proxy audio device overruns its buffer and causes audio artifacts
- Proxying more than two channels of audio
- Ability to increase the number of proxy devices
