# Proxy Audio Device — 构建、签名、公证、分发

从源码到可分发 zip 的完整流程。约定占位符：

| 占位符 | 含义 | 示例形式 |
|---|---|---|
| `<TEAM_ID>` | 10 位 Apple Developer Team ID | `A1B2C3D4E5` |
| `<APPLE_ID>` | Apple ID 登录邮箱 | `you@example.com` |
| `<DEVELOPER_NAME>` | 证书里的开发者/机构名 | `Your Name` 或 `Your Co., Ltd.` |
| `<APP_SPECIFIC_PWD>` | 在 appleid.apple.com 生成的专用密码 | `abcd-efgh-ijkl-mnop` |

---

## 一次性准备

### 1. 证书

在 Xcode **Settings → Accounts → 选中 Team → Manage Certificates** 中创建：

- **Developer ID Application** — 给 `.driver` / `.app` bundle 签名（必需）
- *可选：Developer ID Installer（仅当要做 `.pkg`）*

验证：
```bash
security find-identity -v -p codesigning
# 期待看到：Developer ID Application: <DEVELOPER_NAME> (<TEAM_ID>)
```

### 2. Notary 凭据

1. 在 <https://account.apple.com> → **Sign-In and Security → App-Specific Passwords** 生成一个专用密码
2. 存入 keychain（以后只用 profile 名即可）：

```bash
xcrun notarytool store-credentials "notary-profile" \
    --apple-id "<APPLE_ID>" \
    --team-id "<TEAM_ID>" \
    --password "<APP_SPECIFIC_PWD>"
```

---

## 每次发布流程

### 1. 清理 & 构建

通用二进制（x86_64 + arm64）。`ENABLE_HARDENED_RUNTIME` 与 `OTHER_CODE_SIGN_FLAGS="--timestamp"` 已固化在 `project.pbxproj` 的 Release 配置里，这里不再重复指定：

```bash
rm -rf build dist/ProxyAudioDevice-local dist/ProxyAudioDevice-local.zip

COMMON_ARGS=(
  -project proxyAudioDevice.xcodeproj
  -configuration Release
  build
  ONLY_ACTIVE_ARCH=NO ARCHS="x86_64 arm64"
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=<TEAM_ID>
  CODE_SIGN_IDENTITY="Developer ID Application"
  CONFIGURATION_BUILD_DIR="$PWD/build/Release"
)

xcodebuild -target "ProxyAudioDevice"              "${COMMON_ARGS[@]}"
xcodebuild -target "Proxy Audio Device Settings"   "${COMMON_ARGS[@]}"
```

### 2. 验证签名

```bash
for target in \
    "build/Release/ProxyAudioDevice.driver" \
    "build/Release/Proxy Audio Device Settings.app"
do
    echo "=== $target ==="
    codesign -dv --verbose=4 "$target" 2>&1 \
        | grep -E "Authority|Timestamp|flags"
done
```

**必须**都看到：
- `Authority=Developer ID Application: ...`
- `Timestamp=...`（真实时间戳，不是 `signed=` 本地时钟）
- `flags=0x10000(runtime)` 或包含 `runtime`

缺任何一项，公证就会失败。

### 3. 公证

notarytool 只收 zip/pkg/dmg，且每个 submission 内**只能含一个** bundle。分别打包：

```bash
rm -f driver.zip app.zip
ditto -c -k --keepParent build/Release/ProxyAudioDevice.driver driver.zip
ditto -c -k --keepParent "build/Release/Proxy Audio Device Settings.app" app.zip

xcrun notarytool submit driver.zip --keychain-profile "notary-profile" --wait
xcrun notarytool submit app.zip    --keychain-profile "notary-profile" --wait
```

两次都应看到 `status: Accepted`。如果 `Invalid`，拉日志：

```bash
xcrun notarytool log <submission-id> --keychain-profile "notary-profile"
```

常见问题与排查：

| 日志 message | 原因 | 修法 |
|---|---|---|
| `The signature does not include a secure timestamp` | 签名时没加 `--timestamp` | 检查 `project.pbxproj` Release 配置的 `OTHER_CODE_SIGN_FLAGS` 是否含 `--timestamp` |
| `The executable does not have the hardened runtime enabled` | 没启用 hardened runtime | 检查 `project.pbxproj` 里 `ENABLE_HARDENED_RUNTIME = YES` |
| `The binary is not signed with a valid Developer ID certificate` | 用了 Apple Distribution / 自签 | 必须是 **Developer ID Application** |

### 4. Staple

公证成功后，把票据嵌进 bundle（这样离线机器也能验证）：

```bash
xcrun stapler staple build/Release/ProxyAudioDevice.driver
xcrun stapler staple "build/Release/Proxy Audio Device Settings.app"

# 最终校验
xcrun stapler validate build/Release/ProxyAudioDevice.driver
spctl -a -vv -t install build/Release/ProxyAudioDevice.driver
spctl -a -vv "build/Release/Proxy Audio Device Settings.app"
```

`spctl` 期望输出包含 `accepted` 和 `source=Notarized Developer ID`。

### 5. 打包分发

```bash
STAGE="dist/ProxyAudioDevice-local"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R build/Release/ProxyAudioDevice.driver "$STAGE/"
cp -R "build/Release/Proxy Audio Device Settings.app" "$STAGE/"
cp dist/install.sh dist/uninstall.sh dist/README.txt "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "dist/ProxyAudioDevice-local.zip"
```

产物：`dist/ProxyAudioDevice-local.zip`。

---

## 安全提示

- **不要**把 `<APP_SPECIFIC_PWD>` 写进 shell 历史、脚本或 CI 明文——只在首次 `store-credentials` 使用，之后用 `--keychain-profile` 即可
- `notary-profile` 本身存在登录钥匙串，换机器需重新 `store-credentials`
- Developer ID 证书的私钥同理；换机器前先 **钥匙串访问.app → 导出 `.p12`** 备份
- 如果仓库公开，**不要**把 `DEVELOPMENT_TEAM` 的实际值写死在 `project.pbxproj`；用 xcconfig 或 CI 环境变量覆盖

---

## 一键发布脚本（可选）

保存为 `release.sh`，填好占位符：

```bash
#!/bin/bash
set -euo pipefail

TEAM_ID="<TEAM_ID>"
NOTARY_PROFILE="notary-profile"

rm -rf build dist/ProxyAudioDevice-local dist/ProxyAudioDevice-local.zip

COMMON_ARGS=(
  -project proxyAudioDevice.xcodeproj
  -configuration Release build
  ONLY_ACTIVE_ARCH=NO ARCHS="x86_64 arm64"
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM="$TEAM_ID"
  CODE_SIGN_IDENTITY="Developer ID Application"
  CONFIGURATION_BUILD_DIR="$PWD/build/Release"
)

xcodebuild -target "ProxyAudioDevice"            "${COMMON_ARGS[@]}"
xcodebuild -target "Proxy Audio Device Settings" "${COMMON_ARGS[@]}"

ditto -c -k --keepParent build/Release/ProxyAudioDevice.driver driver.zip
ditto -c -k --keepParent "build/Release/Proxy Audio Device Settings.app" app.zip
xcrun notarytool submit driver.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun notarytool submit app.zip    --keychain-profile "$NOTARY_PROFILE" --wait
rm -f driver.zip app.zip

xcrun stapler staple build/Release/ProxyAudioDevice.driver
xcrun stapler staple "build/Release/Proxy Audio Device Settings.app"

STAGE="dist/ProxyAudioDevice-local"
mkdir -p "$STAGE"
cp -R build/Release/ProxyAudioDevice.driver "$STAGE/"
cp -R "build/Release/Proxy Audio Device Settings.app" "$STAGE/"
cp dist/install.sh dist/uninstall.sh dist/README.txt "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "dist/ProxyAudioDevice-local.zip"

echo "OK -> dist/ProxyAudioDevice-local.zip"
```
