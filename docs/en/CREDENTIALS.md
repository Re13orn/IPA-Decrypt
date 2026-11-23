# Credential guide

[English](CREDENTIALS.md) · [简体中文](../CREDENTIALS.md)

## Choose a source

### Recover a model from this Mac

On a supported Apple Silicon Mac, install and open a compatible iPhone or iPad app from the Mac App Store. In IPA Decrypt, choose **FairPlay 凭据 → 获取凭据 → 从这台 Mac 提取模型**. Select the installed app and choose **提取并验证模型**; macOS will request administrator authorization to read the local registration state.

The app saves the recovered model after validation. You can then view it or choose an IPA from the processing records. A jailbroken iPhone is not required for this route.

The scanner checks `/Applications`, `~/Applications`, and their subfolders for iOS FairPlay license files. Use **选择其他应用…** for other locations. The number of detected apps is not the number of distinct credentials, and detecting a license file does not establish that extraction will succeed.

### Extract from a jailbroken iPhone or iPad

Choose **越狱设备提取**, select USB or IP/host, enter SSH details, and test the connection. The device must be jailbroken and running SSH even when connected by USB.

Choose **全部提取并去重** to scan and process supported sources. Confirmed credentials are saved automatically and identical bytes are grouped. Incomplete sources remain available for investigation or retry. Expand the optional IPA-source section only when matching a specific IPA source is needed.

The resulting 16-byte credentials can be used by both the Mac and iOS apps.

### Import an existing credential

Import `credential.bin`, or paste its 32-character hexadecimal representation. Mac also supports local model files. iOS accepts 16-byte credentials, not Mac model files.

## Use the result

Downloaded or imported IPAs are checked against saved credential candidates. Account labels affect the candidate order; they do not exclude other saved 16-byte credentials. Identical byte values are tried once. Compatibility is established by license verification.

For an existing original IPA, choose **选择 IPA 解密** and continue in its processing record. For a new download or import, the app first retains the complete original package, then attempts decryption.

## When nothing matches

Keep the original IPA. Import another matching credential, or recover a model from a Store registration state compatible with that IPA. Editing an account label does not change the credential bytes or make a license pass verification.

A model's validation result applies to the selected validation app. Other IPAs are verified separately. Mac models are a different format from 16-byte `credential.bin`; they cannot be converted to that format for iOS use.
