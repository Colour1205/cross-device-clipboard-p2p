// Step 7 of the build order in ../../../../README.md: signing/verification
// + trust store integration. Mirrors windows/daemon/Crypto/SigningService.cs
// and windows/daemon/Storage/ClipboardEntry.cs exactly.
//
// Timestamp handling is the one subtlety here. ClipboardEntry.cs's
// Timestamp is a real DateTime, and SigningService.cs signs over
// `entry.Timestamp.ToString("o")` - .NET's round-trip format, 7 fractional
// digits (e.g. "2026-09-19T18:46:00.1234567Z"). JS's Date only has
// millisecond precision, so re-parsing an incoming timestamp into a Date
// and reformatting it would silently truncate/alter any real sub-
// millisecond precision a Windows-originated entry has - and then this
// device's re-derived signing string would no longer match what the
// signer actually signed, breaking verification for most genuine
// Windows-sent entries.
// The fix: never parse Timestamp into a Date at all. Treat it as an opaque
// string straight out of JSON, both when verifying (use the exact string
// as received) and when originating a new entry (generate a valid "o"-
// format string directly). This is safe because .NET's "o" format is
// specifically designed to round-trip losslessly - parsing a well-formed
// "o" string and reformatting it with "o" reproduces the identical string.

import { util } from '@kit.ArkTS';
import { DeviceIdentity, verifyRawSignature } from '../identity/DeviceIdentity';

const base64Helper = new util.Base64Helper();

export interface ClipboardEntry {
  Content: string;
  Type: string;
  DeviceId: string;
  Timestamp: string; // always opaque - see file header
  Signature?: string;
}

function stringToBytes(s: string): Uint8Array {
  return new Uint8Array(Array.from(s).map(c => c.charCodeAt(0)));
}

// Matches .NET's DateTime.ToString("o") for a freshly-generated UTC
// timestamp: yyyy-MM-ddTHH:mm:ss.fffffffZ, exactly 7 fractional digits.
// JS's toISOString() gives exactly 3 - pad with 4 zeros. Since those
// trailing digits are genuinely zero (this device has no finer time
// source than milliseconds to offer anyway), .NET parsing this string and
// reformatting via "o" reproduces it exactly, byte for byte.
export function nowAsDotNetRoundTrip(): string {
  const iso = new Date().toISOString(); // "...ss.SSSZ"
  return `${iso.slice(0, -1)}0000Z`;
}

function signableData(entry: ClipboardEntry): Uint8Array {
  return stringToBytes(`${entry.Content}:${entry.Type}:${entry.DeviceId}:${entry.Timestamp}`);
}

export async function signEntry(identity: DeviceIdentity, content: string, type: string, deviceId: string): Promise<ClipboardEntry> {
  const entry: ClipboardEntry = { Content: content, Type: type, DeviceId: deviceId, Timestamp: nowAsDotNetRoundTrip() };
  const signature = await identity.sign(signableData(entry));
  entry.Signature = base64Helper.encodeToStringSync(signature);
  return entry;
}

// Verifies against entry.DeviceId itself - matches how Program.cs always
// calls SigningService.Verify(entry, entry.DeviceId) in practice.
export async function verifyEntry(entry: ClipboardEntry): Promise<boolean> {
  if (!entry.Signature) return false;
  let sigBytes: Uint8Array;
  try {
    sigBytes = base64Helper.decodeSync(entry.Signature);
  } catch (e) {
    return false; // malformed base64 from a misbehaving/hostile peer
  }
  return await verifyRawSignature(entry.DeviceId, signableData(entry), sigBytes);
}
