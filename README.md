## Proxy Audio Driver

A HAL virtual audio driver for macOS that sends all output to another audio device. Its main purpose is to make it possible to use macOS's system volume controls, such as the volume menu bar icon or volume keyboard keys, to change the volume of external audio interfaces that don't allow it. It might be useful for something else, too.

### Changes in this fork

- **Fix: audio resumes automatically after macOS sleep/wake.** Previously the proxy device went silent after wake until you manually toggled the system output device. The driver now hooks IOKit power notifications (`IORegisterForSystemPower`) and rebuilds its IOProc on wake.
- **Build script: `rebuild-and-install.sh`.** One command rebuilds the driver with your own signing identity, installs it to `/Library/Audio/Plug-Ins/HAL/`, and restarts coreaudiod (with a SIP-aware fallback for macOS 26+). Signing config lives in a gitignored `rebuild-and-install.config`, so your team ID never enters version control.

### Installation

#### Install with a package manager

[![Packaging status on repology](https://repology.org/badge/vertical-allrepos/proxy-audio-device.svg)](https://repology.org/project/proxy-audio-device/versions)

Install [proxy-audio-device with Homebrew with `brew`](https://formulae.brew.sh/cask/proxy-audio-device):

    brew install --cask proxy-audio-device

_or_ [proxy-audio-device on macports with `port`](https://ports.macports.org/port/proxy-audio-device/):

    sudo port install proxy-audio-device

Run the _Proxy Audio Device Settings_ app to configure your new audio device.

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

### Uninstallation

1. Open a terminal window and execute the following command:

        sudo rm -rf /Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver

2. Either reboot your system or reboot Core Audio by executing the following command:

        # macOS <= 13
        sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
   
        # macOS >= 14.4
        sudo killall coreaudiod

### Building

#### Quick build & install (recommended)

```bash
cp rebuild-and-install.config.template rebuild-and-install.config
$EDITOR rebuild-and-install.config        # fill in DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY
./rebuild-and-install.sh                  # build + install + restart coreaudiod
```

List available signing identities with `security find-identity -v -p codesigning`. The config file is gitignored.

Other flags: `--build` (skip install), `--no-clean` (incremental build).

If both `launchctl kickstart` and `killall coreaudiod` are blocked (very rare), the script prints a highlighted prompt asking you to run `sudo killall coreaudiod` manually, or log out / reboot.

#### Manual build

Clone the repo, open the Xcode project and build the driver and the settings application. Then follow the installation instructions above.


### Issues

If you make the audio buffer too small then the driver will introduce pops, crackles, or distortion. If you notice that then try increasing the buffer size.


### Possible Future Work

- Indicator in the settings app for when the proxy audio device overruns its buffer and causes audio artifacts
- Proxying more than two channels of audio
- Ability to increase the number of proxy devices
