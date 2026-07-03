#Requires -Version 5.1
# SAM offline account recovery — layouts per chntpw sam.h (pwdump/Samba reference).
# NT OWF per Microsoft: MD4(UTF-16LE password). SAM stores DES-obfuscated hash keyed by RID.

# user_F offsets (chntpw sam.h)
$Script:SamF_AcbBitsOffset    = 0x38
$Script:SamF_FailedCountOffset = 0x40
$Script:SamF_MinLength        = 0x48

# user_V offsets (chntpw sam.h)
$Script:SamV_HeaderSize     = 0xCC
$Script:SamV_LmPwOfsOffset  = 0x9C
$Script:SamV_LmPwLenOffset  = 0xA0
$Script:SamV_NtPwOfsOffset  = 0xA8
$Script:SamV_NtPwLenOffset  = 0xAC
$Script:SamV_MinLength      = 0xCC

# ACB_bits flags (chntpw sam.h)
$Script:AcbDisabled  = 0x0001
$Script:AcbNormal    = 0x0010
$Script:AcbPwNoExp   = 0x0200
$Script:AcbAutolock  = 0x0400

function Initialize-OfflineSamCrypto {
    if (([System.Management.Automation.PSTypeName]'CdeSamCrypto').Type) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public static class CdeSamCrypto {
    public static byte[] ComputeNtMd4(string password) {
        if (password == null) { return null; }
        return Md4.Hash(Encoding.Unicode.GetBytes(password));
    }

    public static byte[] EncryptNtHashForRid(byte[] ntMd4, uint rid) {
        if (ntMd4 == null || ntMd4.Length != 16) { return null; }
        byte[] key1 = SidToDesKey1(rid);
        byte[] key2 = SidToDesKey2(rid);
        byte[] block1 = DesEcbEncrypt(ntMd4, 0, key1);
        byte[] block2 = DesEcbEncrypt(ntMd4, 8, key2);
        byte[] outBytes = new byte[16];
        Buffer.BlockCopy(block1, 0, outBytes, 0, 8);
        Buffer.BlockCopy(block2, 0, outBytes, 8, 8);
        return outBytes;
    }

    public static byte[] DecryptNtHashForRid(byte[] encrypted, uint rid) {
        if (encrypted == null || encrypted.Length != 16) { return null; }
        byte[] key1 = SidToDesKey1(rid);
        byte[] key2 = SidToDesKey2(rid);
        byte[] block1 = DesEcbDecrypt(encrypted, 0, key1);
        byte[] block2 = DesEcbDecrypt(encrypted, 8, key2);
        byte[] outBytes = new byte[16];
        Buffer.BlockCopy(block1, 0, outBytes, 0, 8);
        Buffer.BlockCopy(block2, 0, outBytes, 8, 8);
        return outBytes;
    }

    public static string BytesToHex(byte[] data) {
        if (data == null) { return string.Empty; }
        var sb = new StringBuilder(data.Length * 2);
        for (int i = 0; i < data.Length; i++) {
            sb.Append(data[i].ToString("X2"));
        }
        return sb.ToString();
    }

    private static byte[] SidToDesKey1(uint rid) {
        byte[] s = new byte[7];
        s[0] = (byte)(rid & 0xFF);
        s[1] = (byte)((rid >> 8) & 0xFF);
        s[2] = (byte)((rid >> 16) & 0xFF);
        s[3] = (byte)((rid >> 24) & 0xFF);
        s[4] = s[0];
        s[5] = s[1];
        s[6] = s[2];
        return StrToKey(s);
    }

    private static byte[] SidToDesKey2(uint rid) {
        byte[] s = new byte[7];
        s[0] = (byte)((rid >> 24) & 0xFF);
        s[1] = (byte)(rid & 0xFF);
        s[2] = (byte)((rid >> 8) & 0xFF);
        s[3] = (byte)((rid >> 16) & 0xFF);
        s[4] = s[0];
        s[5] = s[1];
        s[6] = s[2];
        return StrToKey(s);
    }

    private static byte[] StrToKey(byte[] str7) {
        byte[] key = new byte[8];
        key[0] = (byte)(str7[0] >> 1);
        key[1] = (byte)(((str7[0] & 0x01) << 6) | (str7[1] >> 2));
        key[2] = (byte)(((str7[1] & 0x03) << 5) | (str7[2] >> 3));
        key[3] = (byte)(((str7[2] & 0x07) << 4) | (str7[3] >> 4));
        key[4] = (byte)(((str7[3] & 0x0F) << 3) | (str7[4] >> 5));
        key[5] = (byte)(((str7[4] & 0x1F) << 2) | (str7[5] >> 6));
        key[6] = (byte)(((str7[5] & 0x3F) << 1) | (str7[6] >> 7));
        key[7] = (byte)(str7[6] & 0x7F);
        for (int i = 0; i < 8; i++) {
            key[i] = (byte)(key[i] << 1);
        }
        SetDesOddParity(key);
        return key;
    }

    private static void SetDesOddParity(byte[] key) {
        for (int i = 0; i < 8; i++) {
            int b = key[i];
            if ((b & 1) == 0) {
                key[i] = (byte)(b | 1);
            }
        }
    }

    private static byte[] DesEcbEncrypt(byte[] data, int offset, byte[] key) {
        using (var des = DES.Create()) {
            des.Mode = CipherMode.ECB;
            des.Padding = PaddingMode.None;
            des.Key = key;
            using (var enc = des.CreateEncryptor()) {
                byte[] input = new byte[8];
                Buffer.BlockCopy(data, offset, input, 0, 8);
                return enc.TransformFinalBlock(input, 0, 8);
            }
        }
    }

    private static byte[] DesEcbDecrypt(byte[] data, int offset, byte[] key) {
        using (var des = DES.Create()) {
            des.Mode = CipherMode.ECB;
            des.Padding = PaddingMode.None;
            des.Key = key;
            using (var dec = des.CreateDecryptor()) {
                byte[] input = new byte[8];
                Buffer.BlockCopy(data, offset, input, 0, 8);
                return dec.TransformFinalBlock(input, 0, 8);
            }
        }
    }
}

internal static class Md4 {
    public static byte[] Hash(byte[] input) {
        uint a = 0x67452301, b = 0xefcdab89, c = 0x98badcfe, d = 0x10325476;
        int origLen = input.Length;
        ulong bitLen = (ulong)origLen * 8UL;
        int padLen = (56 - ((origLen + 1) % 64) + 64) % 64;
        byte[] msg = new byte[origLen + 1 + padLen + 8];
        Buffer.BlockCopy(input, 0, msg, 0, origLen);
        msg[origLen] = 0x80;
        for (int i = 0; i < 8; i++) {
            msg[msg.Length - 8 + i] = (byte)(bitLen >> (8 * i));
        }

        for (int offset = 0; offset < msg.Length; offset += 64) {
            uint[] x = new uint[16];
            for (int i = 0; i < 16; i++) {
                x[i] = BitConverter.ToUInt32(msg, offset + (i * 4));
            }
            uint aa = a, bb = b, cc = c, dd = d;
            R1(ref aa, ref bb, ref cc, ref dd, x[0], 3);  R1(ref dd, ref aa, ref bb, ref cc, x[1], 7);
            R1(ref cc, ref dd, ref aa, ref bb, x[2], 11); R1(ref bb, ref cc, ref dd, ref aa, x[3], 19);
            R1(ref aa, ref bb, ref cc, ref dd, x[4], 3);  R1(ref dd, ref aa, ref bb, ref cc, x[5], 7);
            R1(ref cc, ref dd, ref aa, ref bb, x[6], 11); R1(ref bb, ref cc, ref dd, ref aa, x[7], 19);
            R1(ref aa, ref bb, ref cc, ref dd, x[8], 3);  R1(ref dd, ref aa, ref bb, ref cc, x[9], 7);
            R1(ref cc, ref dd, ref aa, ref bb, x[10], 11);R1(ref bb, ref cc, ref dd, ref aa, x[11], 19);
            R1(ref aa, ref bb, ref cc, ref dd, x[12], 3); R1(ref dd, ref aa, ref bb, ref cc, x[13], 7);
            R1(ref cc, ref dd, ref aa, ref bb, x[14], 11);R1(ref bb, ref cc, ref dd, ref aa, x[15], 19);
            R2(ref aa, ref bb, ref cc, ref dd, x[0], 3);  R2(ref dd, ref aa, ref bb, ref cc, x[4], 5);
            R2(ref cc, ref dd, ref aa, ref bb, x[8], 9);  R2(ref bb, ref cc, ref dd, ref aa, x[12], 13);
            R2(ref aa, ref bb, ref cc, ref dd, x[1], 3);  R2(ref dd, ref aa, ref bb, ref cc, x[5], 5);
            R2(ref cc, ref dd, ref aa, ref bb, x[9], 9);  R2(ref bb, ref cc, ref dd, ref aa, x[13], 13);
            R2(ref aa, ref bb, ref cc, ref dd, x[2], 3);  R2(ref dd, ref aa, ref bb, ref cc, x[6], 5);
            R2(ref cc, ref dd, ref aa, ref bb, x[10], 9); R2(ref bb, ref cc, ref dd, ref aa, x[14], 13);
            R2(ref aa, ref bb, ref cc, ref dd, x[3], 3);  R2(ref dd, ref aa, ref bb, ref cc, x[7], 5);
            R2(ref cc, ref dd, ref aa, ref bb, x[11], 9); R2(ref bb, ref cc, ref dd, ref aa, x[15], 13);
            R3(ref aa, ref bb, ref cc, ref dd, x[0], 3);  R3(ref dd, ref aa, ref bb, ref cc, x[8], 9);
            R3(ref cc, ref dd, ref aa, ref bb, x[4], 11); R3(ref bb, ref cc, ref dd, ref aa, x[12], 15);
            R3(ref aa, ref bb, ref cc, ref dd, x[2], 3);  R3(ref dd, ref aa, ref bb, ref cc, x[10], 9);
            R3(ref cc, ref dd, ref aa, ref bb, x[6], 11); R3(ref bb, ref cc, ref dd, ref aa, x[14], 15);
            R3(ref aa, ref bb, ref cc, ref dd, x[1], 3);  R3(ref dd, ref aa, ref bb, ref cc, x[9], 9);
            R3(ref cc, ref dd, ref aa, ref bb, x[5], 11); R3(ref bb, ref cc, ref dd, ref aa, x[13], 15);
            R3(ref aa, ref bb, ref cc, ref dd, x[3], 3);  R3(ref dd, ref aa, ref bb, ref cc, x[11], 9);
            R3(ref cc, ref dd, ref aa, ref bb, x[7], 11); R3(ref bb, ref cc, ref dd, ref aa, x[15], 15);
            a += aa; b += bb; c += cc; d += dd;
        }

        byte[] outBytes = new byte[16];
        Buffer.BlockCopy(BitConverter.GetBytes(a), 0, outBytes, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(b), 0, outBytes, 4, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(c), 0, outBytes, 8, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(d), 0, outBytes, 12, 4);
        return outBytes;
    }

    private static uint LRot(uint x, int n) { return (x << n) | (x >> (32 - n)); }
    private static void R1(ref uint a, ref uint b, ref uint c, ref uint d, uint x, int s) {
        a = LRot(a + ((b & c) | (~b & d)) + x, s);
    }
    private static void R2(ref uint a, ref uint b, ref uint c, ref uint d, uint x, int s) {
        a = LRot(a + ((b & c) | (b & d) | (c & d)) + x + 0x5a827999, s);
    }
    private static void R3(ref uint a, ref uint b, ref uint c, ref uint d, uint x, int s) {
        a = LRot(a + (b ^ c ^ d) + x + 0x6ed9eba1, s);
    }
}
'@
}

function Get-OfflineSamUserKeyPath {
    param(
        [string]$SamRegistryRoot = 'HKLM:\Offline_SAM',
        [uint32]$RelativeId = 500
    )
    $ridHex = '{0:X8}' -f $RelativeId
    Join-Path $SamRegistryRoot "SAM\Domains\Account\Users\$ridHex"
}

function Get-SamAccountNameFromV {
    param([byte[]]$V)
    if ($null -eq $V -or $V.Length -lt $Script:SamV_MinLength) { return $null }
    $nameOffset = [BitConverter]::ToInt32($V, 0x0C) + $Script:SamV_HeaderSize
    $nameLength = [BitConverter]::ToInt32($V, 0x10)
    if ($nameLength -le 0 -or $nameOffset -lt 0 -or ($nameOffset + $nameLength) -gt $V.Length) {
        return $null
    }
    return [System.Text.Encoding]::Unicode.GetString($V, $nameOffset, $nameLength)
}

function Get-NtOwfPasswordHash {
    param([Parameter(Mandatory)][string]$ClearTextPassword)
    Initialize-OfflineSamCrypto
    $hash = [CdeSamCrypto]::ComputeNtMd4($ClearTextPassword)
    if ($null -eq $hash -or $hash.Length -ne 16) {
        throw 'Failed to compute NT password hash (MD4).'
    }
    return $hash
}

function Get-OfflineSamEncryptedNtHash {
    param(
        [Parameter(Mandatory)][string]$ClearTextPassword,
        [uint32]$RelativeId = 500
    )
    Initialize-OfflineSamCrypto
    $md4 = [CdeSamCrypto]::ComputeNtMd4($ClearTextPassword)
    if ($null -eq $md4 -or $md4.Length -ne 16) {
        throw 'Failed to compute NT password hash (MD4).'
    }
    $encrypted = [CdeSamCrypto]::EncryptNtHashForRid($md4, $RelativeId)
    if ($null -eq $encrypted -or $encrypted.Length -ne 16) {
        throw 'Failed to DES-encrypt NT hash for SAM storage.'
    }
    return [PSCustomObject]@{
        Md4Hash     = $md4
        EncryptedNt = $encrypted
        RelativeId  = $RelativeId
    }
}

function Test-OfflineSamAccountEnabled {
    param(
        [Parameter(Mandatory)][string]$UserKeyPath
    )
    $F = [byte[]](Get-ItemProperty -LiteralPath $UserKeyPath -Name F -ErrorAction Stop).F
    if ($F.Length -lt $Script:SamF_MinLength) {
        throw "SAM F value is too short ($($F.Length) bytes); expected at least $($Script:SamF_MinLength)."
    }
    $acb = [BitConverter]::ToUInt16($F, $Script:SamF_AcbBitsOffset)
    $disabled = ($acb -band $Script:AcbDisabled) -eq $Script:AcbDisabled
    [PSCustomObject]@{
        AcbBits    = $acb
        IsDisabled = $disabled
        IsEnabled  = -not $disabled
    }
}

function Get-OfflineSamAccountPasswordState {
    param(
        [Parameter(Mandatory)][string]$UserKeyPath
    )
    $V = [byte[]](Get-ItemProperty -LiteralPath $UserKeyPath -Name V -ErrorAction Stop).V
    if ($V.Length -lt $Script:SamV_MinLength) {
        throw "SAM V value is too short ($($V.Length) bytes); expected at least $($Script:SamV_MinLength)."
    }
    $ntpwLen = [BitConverter]::ToInt32($V, $Script:SamV_NtPwLenOffset)
    $lmpwLen = [BitConverter]::ToInt32($V, $Script:SamV_LmPwLenOffset)
    $isBlank = ($ntpwLen -lt 16) -and ($lmpwLen -lt 16)
    $canSetPassword = -not $isBlank
    [PSCustomObject]@{
        NtPasswordLength     = $ntpwLen
        LmPasswordLength     = $lmpwLen
        HasNtPassword        = ($ntpwLen -ge 16)
        IsBlankPassword      = $isBlank
        CanSetPasswordOffline = $canSetPassword
    }
}

function Set-OfflineSamAccountPassword {
    param(
        [Parameter(Mandatory)][string]$UserKeyPath,
        [Parameter(Mandatory)][string]$ClearTextPassword,
        [uint32]$RelativeId = 500
    )
    $V = [byte[]](Get-ItemProperty -LiteralPath $UserKeyPath -Name V -ErrorAction Stop).V
    if ($V.Length -lt $Script:SamV_MinLength) {
        throw "SAM V value is too short ($($V.Length) bytes); cannot set password."
    }

    $ntpwOfs = [BitConverter]::ToInt32($V, $Script:SamV_NtPwOfsOffset)
    $ntpwLen = [BitConverter]::ToInt32($V, $Script:SamV_NtPwLenOffset)
    $lmpwOfs = [BitConverter]::ToInt32($V, $Script:SamV_LmPwOfsOffset)
    $lmpwLen = [BitConverter]::ToInt32($V, $Script:SamV_LmPwLenOffset)

    if ($ntpwLen -lt 16) {
        if ($lmpwLen -ge 16) {
            $ntpwOfs = $lmpwOfs
            [BitConverter]::GetBytes($ntpwOfs).CopyTo($V, $Script:SamV_NtPwOfsOffset)
            $ntpwLen = 16
            $lmpwLen = 0
            [BitConverter]::GetBytes($lmpwLen).CopyTo($V, $Script:SamV_LmPwLenOffset)
        }
        else {
            throw @(
                'Built-in Administrator has a blank password with no NT or LM hash storage in SAM (ntpw_len and lmpw_len both under 16). '
                'chntpw documents that hash bytes are missing for blank accounts and refuses to write a new password because it can corrupt SAM / break Netlogon. '
                'Enable the account only, then sign in as .\Administrator with no password and set a password inside Windows.'
            ) -join ''
        }
    }

    $hashOffset = $ntpwOfs + $Script:SamV_HeaderSize
    if ($hashOffset -lt 0 -or ($hashOffset + 16) -gt $V.Length) {
        throw "SAM V NT hash offset is invalid (hashOffset=$hashOffset, V length=$($V.Length))."
    }

    $hashInfo = Get-OfflineSamEncryptedNtHash -ClearTextPassword $ClearTextPassword -RelativeId $RelativeId
    [Array]::Copy($hashInfo.EncryptedNt, 0, $V, $hashOffset, 16)
    [BitConverter]::GetBytes([int32]16).CopyTo($V, $Script:SamV_NtPwLenOffset)

    Set-ItemProperty -LiteralPath $UserKeyPath -Name V -Value $V -Type Binary -ErrorAction Stop
}

function Enable-OfflineSamAccount {
    param(
        [Parameter(Mandatory)][string]$UserKeyPath
    )
    $F = [byte[]](Get-ItemProperty -LiteralPath $UserKeyPath -Name F -ErrorAction Stop).F
    if ($F.Length -lt $Script:SamF_MinLength) {
        throw "SAM F value is too short ($($F.Length) bytes); cannot enable account."
    }

    $acb = [BitConverter]::ToUInt16($F, $Script:SamF_AcbBitsOffset)
    $acb = $acb -bor $Script:AcbPwNoExp
    $acb = $acb -band (-bnot $Script:AcbDisabled)
    $acb = $acb -band (-bnot $Script:AcbAutolock)
    if (($acb -band $Script:AcbNormal) -eq 0) {
        $acb = $acb -bor $Script:AcbNormal
    }
    [BitConverter]::GetBytes([uint16]$acb).CopyTo($F, $Script:SamF_AcbBitsOffset)
    [BitConverter]::GetBytes([uint16]0).CopyTo($F, $Script:SamF_FailedCountOffset)

    Set-ItemProperty -LiteralPath $UserKeyPath -Name F -Value $F -Type Binary -ErrorAction Stop
}

function Disable-OfflineSamAccount {
    param(
        [Parameter(Mandatory)][string]$UserKeyPath
    )
    $F = [byte[]](Get-ItemProperty -LiteralPath $UserKeyPath -Name F -ErrorAction Stop).F
    if ($F.Length -lt $Script:SamF_MinLength) {
        throw "SAM F value is too short ($($F.Length) bytes); cannot disable account."
    }

    $acb = [BitConverter]::ToUInt16($F, $Script:SamF_AcbBitsOffset)
    $acb = $acb -bor $Script:AcbDisabled
    [BitConverter]::GetBytes([uint16]$acb).CopyTo($F, $Script:SamF_AcbBitsOffset)

    Set-ItemProperty -LiteralPath $UserKeyPath -Name F -Value $F -Type Binary -ErrorAction Stop
}

function Test-OfflineSamCryptoValidation {
    Initialize-OfflineSamCrypto

    $errors = [System.Collections.Generic.List[string]]::new()

    $md4 = [CdeSamCrypto]::ComputeNtMd4('password')
    $expectedMd4 = '8846F7EAEE8FB117AD06BDD830B7586C'
    $actualMd4 = [CdeSamCrypto]::BytesToHex($md4)
    if (-not $actualMd4.Equals($expectedMd4, [StringComparison]::OrdinalIgnoreCase)) {
        $errors.Add("MD4 vector failed: expected $expectedMd4 got $actualMd4")
    }

    $rid = [uint32]500
    $encrypted = [CdeSamCrypto]::EncryptNtHashForRid($md4, $rid)
    $roundTrip = [CdeSamCrypto]::DecryptNtHashForRid($encrypted, $rid)
    $roundTripHex = [CdeSamCrypto]::BytesToHex($roundTrip)
    if (-not $roundTripHex.Equals($expectedMd4, [StringComparison]::OrdinalIgnoreCase)) {
        $errors.Add("DES RID $rid round-trip failed: expected $expectedMd4 got $roundTripHex")
    }

    [PSCustomObject]@{
        Pass       = ($errors.Count -eq 0)
        ErrorCount = $errors.Count
        Errors     = $errors
        Md4Hex     = $actualMd4
        Rid        = $rid
    }
}

function Enable-OfflineBuiltInAdministrator {
    param(
        [string]$SamRegistryRoot = 'HKLM:\Offline_SAM'
    )
    $userKey = Get-OfflineSamUserKeyPath -SamRegistryRoot $SamRegistryRoot -RelativeId 500
    if (-not (Test-Path -LiteralPath $userKey)) {
        throw "Built-in Administrator account was not found at $userKey. Is Offline_SAM loaded?"
    }

    $before = Test-OfflineSamAccountEnabled -UserKeyPath $userKey
    $accountName = Get-SamAccountNameFromV -V ([byte[]](Get-ItemProperty -LiteralPath $userKey -Name V).V)

    Enable-OfflineSamAccount -UserKeyPath $userKey

    $after = Test-OfflineSamAccountEnabled -UserKeyPath $userKey
    if (-not $after.IsEnabled) {
        throw "Administrator account is still disabled (ACB_bits=0x$('{0:X4}' -f $after.AcbBits))."
    }

    [PSCustomObject]@{
        AccountName = if ($accountName) { $accountName } else { 'Administrator' }
        UserKeyPath = $userKey
        WasDisabled = $before.IsDisabled
        IsEnabled   = $after.IsEnabled
        AcbBits     = $after.AcbBits
        RelativeId  = 500
    }
}

function Disable-OfflineBuiltInAdministrator {
    param(
        [string]$SamRegistryRoot = 'HKLM:\Offline_SAM'
    )
    $userKey = Get-OfflineSamUserKeyPath -SamRegistryRoot $SamRegistryRoot -RelativeId 500
    if (-not (Test-Path -LiteralPath $userKey)) {
        throw "Built-in Administrator account was not found at $userKey. Is Offline_SAM loaded?"
    }

    $before = Test-OfflineSamAccountEnabled -UserKeyPath $userKey
    $accountName = Get-SamAccountNameFromV -V ([byte[]](Get-ItemProperty -LiteralPath $userKey -Name V).V)

    Disable-OfflineSamAccount -UserKeyPath $userKey

    $after = Test-OfflineSamAccountEnabled -UserKeyPath $userKey
    if (-not $after.IsDisabled) {
        throw "Administrator account is still enabled (ACB_bits=0x$('{0:X4}' -f $after.AcbBits))."
    }

    [PSCustomObject]@{
        AccountName = if ($accountName) { $accountName } else { 'Administrator' }
        UserKeyPath = $userKey
        WasEnabled  = $before.IsEnabled
        IsDisabled  = $after.IsDisabled
        AcbBits     = $after.AcbBits
        RelativeId  = 500
    }
}

function Backup-OfflineSamHiveFile {
    param(
        [Parameter(Mandatory)][string]$OfflineWindowsRoot,
        [string]$SamRegistryRoot = 'HKLM:\Offline_SAM',
        [string]$BackupRoot = $(Join-Path $env:ProgramData 'CDE\AccountRecovery\Backups')
    )
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dest = Join-Path $BackupRoot "SAM_$stamp.hiv"

    if (Test-Path -LiteralPath $SamRegistryRoot) {
        $regPath = $SamRegistryRoot -replace '^HKLM:\\', 'HKLM\'
        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        $proc = Start-Process -FilePath $regExe `
            -ArgumentList @('save', $regPath, $dest, '/y') `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $dest)) {
            throw "reg save failed to back up loaded SAM hive (exit $($proc.ExitCode))."
        }
        return $dest
    }

    $samPath = Join-Path $OfflineWindowsRoot 'Windows\System32\config\SAM'
    if (-not (Test-Path -LiteralPath $samPath)) {
        throw "SAM hive file not found: $samPath"
    }
    $dest = Join-Path $BackupRoot "SAM_$stamp.bak"
    Copy-Item -LiteralPath $samPath -Destination $dest -Force
    return $dest
}

Export-ModuleMember -Function @(
    'Get-OfflineSamUserKeyPath',
    'Get-NtOwfPasswordHash',
    'Get-OfflineSamEncryptedNtHash',
    'Test-OfflineSamAccountEnabled',
    'Get-OfflineSamAccountPasswordState',
    'Test-OfflineSamCryptoValidation',
    'Enable-OfflineBuiltInAdministrator',
    'Disable-OfflineBuiltInAdministrator',
    'Backup-OfflineSamHiveFile'
)
