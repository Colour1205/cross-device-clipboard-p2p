// HUKS produces/expects DER (ASN.1 SEQUENCE of two INTEGERs) ECDSA
// signatures; .NET's ECDsa.SignData/VerifyData default to raw, fixed-width
// r||s ("IEEE P1363") signatures instead — confirmed empirically in the
// step-2 protocol compatibility spike (see README.md). This is the
// conversion layer that makes the two interoperate.
//
// Only handles P-256 (32-byte field elements, 64-byte raw signatures) —
// this app never signs with any other curve.

const FIELD_BYTES = 32;

// DER INTEGER content for r or s: strip a single leading 0x00 padding byte
// (present only to keep the value unsigned when its own high bit is set),
// then left-pad with zeros out to the fixed field width.
function derIntegerToFixedWidth(bytes: Uint8Array): Uint8Array {
  let start = 0;
  if (bytes.length > FIELD_BYTES && bytes[0] === 0x00) {
    start = 1;
  }
  const trimmed = bytes.slice(start);
  if (trimmed.length > FIELD_BYTES) {
    throw new Error(`DER integer too large for P-256 (${trimmed.length} bytes)`);
  }
  const out = new Uint8Array(FIELD_BYTES);
  out.set(trimmed, FIELD_BYTES - trimmed.length);
  return out;
}

// Fixed-width r or s -> minimal-length DER INTEGER content: strip leading
// zero bytes, then prepend a single 0x00 if the remaining high bit is set
// (otherwise it would be misread as a negative number in DER's signed
// INTEGER encoding).
function fixedWidthToDerInteger(bytes: Uint8Array): Uint8Array {
  let start = 0;
  while (start < bytes.length - 1 && bytes[start] === 0x00) {
    start++;
  }
  const trimmed = bytes.slice(start);
  if (trimmed[0] & 0x80) {
    const padded = new Uint8Array(trimmed.length + 1);
    padded.set(trimmed, 1);
    return padded;
  }
  return trimmed;
}

// DER length encoding, short-form only (P-256 integers are at most 33
// bytes, so content length here never approaches 128).
function derLen(len: number): Uint8Array {
  if (len >= 128) {
    throw new Error(`DER length ${len} needs long-form encoding, not implemented (unexpected for P-256)`);
  }
  return new Uint8Array([len]);
}

function concatAll(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, p) => sum + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

// DER SEQUENCE{INTEGER r, INTEGER s} -> raw r(32) || s(32), 64 bytes total.
export function derToRaw(der: Uint8Array): Uint8Array {
  if (der.length < 8 || der[0] !== 0x30) {
    throw new Error('not a DER ECDSA signature (missing SEQUENCE tag)');
  }
  let offset = 2; // skip SEQUENCE tag + length byte (short-form only, matches what HUKS produces for P-256)

  if (der[offset] !== 0x02) throw new Error('expected INTEGER tag for r');
  offset++;
  const rLen = der[offset];
  offset++;
  const r = der.slice(offset, offset + rLen);
  offset += rLen;

  if (der[offset] !== 0x02) throw new Error('expected INTEGER tag for s');
  offset++;
  const sLen = der[offset];
  offset++;
  const s = der.slice(offset, offset + sLen);

  return concatAll([derIntegerToFixedWidth(r), derIntegerToFixedWidth(s)]);
}

// raw r(32) || s(32) -> DER SEQUENCE{INTEGER r, INTEGER s}.
export function rawToDer(raw: Uint8Array): Uint8Array {
  if (raw.length !== FIELD_BYTES * 2) {
    throw new Error(`expected a ${FIELD_BYTES * 2}-byte raw signature, got ${raw.length}`);
  }
  const rInt = fixedWidthToDerInteger(raw.slice(0, FIELD_BYTES));
  const sInt = fixedWidthToDerInteger(raw.slice(FIELD_BYTES));

  const rEncoded = concatAll([new Uint8Array([0x02]), derLen(rInt.length), rInt]);
  const sEncoded = concatAll([new Uint8Array([0x02]), derLen(sInt.length), sInt]);
  const content = concatAll([rEncoded, sEncoded]);

  return concatAll([new Uint8Array([0x30]), derLen(content.length), content]);
}
