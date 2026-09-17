// Protocol compatibility spike (build order step 2 in ../../../../README.md).
// Not a real app screen — a throwaway test harness to prove HarmonyOS crypto
// APIs can interoperate with the Windows daemon's .NET crypto before any
// real app structure gets built on top of unverified assumptions.

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import deviceInfo from '@ohos.deviceInfo';

// Reference values computed on .NET (same primitives PassphraseAuth.cs uses)
// via `dotnet run` against a throwaway console project — see chat history.
// If the PBKDF2 test below doesn't match this, the fixed salt/iteration
// count must differ from what ArkTS actually derived, and passphrase
// auto-trust between Windows and HarmonyOS devices will silently never work.
const REFERENCE_PASSPHRASE = 'clipboard-test-passphrase-1';
const REFERENCE_SALT = 'ClipboardDaemonPassphraseSaltV1';
const REFERENCE_ITERATIONS = 210_000;
const REFERENCE_KEY_SIZE_BITS = 256;
const REFERENCE_PBKDF2_HEX = 'D6DFE5A76379B8105A042A6DD76379E635B922C9AA3D58CE7FBD6627BBD46BE5'.toLowerCase();

const HUKS_KEY_ALIAS = 'clipboard-spike-test-key';
const SIGN_MESSAGE = 'clipboard-protocol-test';

// Independent of the PBKDF2 reference above — isolates whether HMAC-SHA256
// itself works via cryptoFramework, regardless of the PBKDF2 failure.
const HMAC_KEY = 'fixed-test-hmac-key';
const HMAC_MESSAGE = 'fixed-test-hmac-message';
const REFERENCE_HMAC_HEX = '33793F3D7A08AE35B55A7DBFDEA48CA2A57ED7788521D34D630699B261D9DFBA'.toLowerCase();
const REFERENCE_PBKDF2_1000_HEX = '689F10F10E68F6370C4E33BF59E6DC746995A444CE280B0D90C67C08552D3AE7'.toLowerCase();

function toHex(data: Uint8Array): string {
  let out = '';
  for (let i = 0; i < data.length; i++) {
    out += data[i].toString(16).padStart(2, '0');
  }
  return out;
}

function stringToBytes(s: string): Uint8Array {
  return new Uint8Array(Array.from(s).map(c => c.charCodeAt(0)));
}

function xorInPlace(a: Uint8Array, b: Uint8Array): void {
  for (let i = 0; i < a.length; i++) {
    a[i] = a[i] ^ b[i];
  }
}

function int32BE(n: number): Uint8Array {
  return new Uint8Array([(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff]);
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

// Manual PBKDF2-HMAC-SHA256, built directly on cryptoFramework's HMAC
// primitive (confirmed working, unlike Kdf.generateSecret's PBKDF2 path on
// this device/OS build — see the compatibility spike's test 1 vs test 3).
// Standard construction: DK = T_1 || T_2 || ... ; T_i = U_1 xor U_2 xor ...
// xor U_c ; U_1 = HMAC(P, S || INT_32_BE(i)) ; U_j = HMAC(P, U_{j-1}).
// The SymKey is converted once and reused across every iteration — only the
// message being MAC'd changes — since re-deriving it per call would be both
// unnecessary and slow.
async function pbkdf2Sha256Manual(password: Uint8Array, salt: Uint8Array, iterations: number, keyLenBytes: number): Promise<Uint8Array> {
  const hLen = 32; // SHA-256 output size
  const blockCount = Math.ceil(keyLenBytes / hLen);

  const keyGen = cryptoFramework.createSymKeyGenerator('HMAC');
  const symKey = await keyGen.convertKey({ data: password });
  const mac = cryptoFramework.createMac('SHA256');

  const dk = new Uint8Array(blockCount * hLen);
  for (let blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
    await mac.init(symKey);
    await mac.update({ data: concatBytes(salt, int32BE(blockIndex)) });
    let u = (await mac.doFinal()).data;
    const t = new Uint8Array(u);
    for (let iter = 2; iter <= iterations; iter++) {
      await mac.init(symKey);
      await mac.update({ data: u });
      u = (await mac.doFinal()).data;
      xorInPlace(t, u);
    }
    dk.set(t, (blockIndex - 1) * hLen);
  }
  return dk.slice(0, keyLenBytes);
}

@Entry
@Component
struct Index {
  @State pbkdf2Status: string = 'not run yet';
  @State pbkdf2Detail: string = '';
  @State huksStatus: string = 'not run yet';
  @State huksDetail: string = '';
  @State hmacStatus: string = 'not run yet';
  @State hmacDetail: string = '';
  @State manualPbkdf2Status: string = 'not run yet';
  @State manualPbkdf2Detail: string = '';

  async runManualPbkdf2Test(iterations: number, referenceHex: string) {
    this.manualPbkdf2Status = 'running... (this can take a while at high iteration counts)';
    this.manualPbkdf2Detail = '';
    const start = Date.now();
    try {
      const dk = await pbkdf2Sha256Manual(
        stringToBytes(REFERENCE_PASSPHRASE),
        stringToBytes(REFERENCE_SALT),
        iterations,
        REFERENCE_KEY_SIZE_BITS / 8);
      const hex = toHex(dk).toLowerCase();
      const elapsedMs = Date.now() - start;
      const match = hex === referenceHex;
      this.manualPbkdf2Status = match
        ? `MATCH at iterations=${iterations} (${elapsedMs}ms) — manual workaround is correct`
        : `MISMATCH at iterations=${iterations} — implementation bug, do not use yet`;
      this.manualPbkdf2Detail =
        `derived (hex): ${hex}\n` +
        `reference (hex): ${referenceHex}\n` +
        `elapsed: ${elapsedMs}ms`;
    } catch (e) {
      const elapsedMs = Date.now() - start;
      this.manualPbkdf2Status = 'ERROR';
      const be = e as BusinessError;
      this.manualPbkdf2Detail = `code: ${be.code}\nmessage: ${be.message}\nraw: ${JSON.stringify(e)}\nelapsed: ${elapsedMs}ms`;
    }
  }

  async runHmacTest() {
    this.hmacStatus = 'running...';
    this.hmacDetail = '';
    try {
      const keyGen = cryptoFramework.createSymKeyGenerator('HMAC');
      const symKey = await keyGen.convertKey({ data: stringToBytes(HMAC_KEY) });
      this.hmacDetail += 'createSymKeyGenerator + convertKey: OK\n';

      const mac = cryptoFramework.createMac('SHA256');
      await mac.init(symKey);
      await mac.update({ data: stringToBytes(HMAC_MESSAGE) });
      const result = await mac.doFinal();
      const hex = toHex(result.data).toLowerCase();
      const match = hex === REFERENCE_HMAC_HEX;
      this.hmacStatus = match ? 'MATCH — HMAC works on this device' : 'MISMATCH — HMAC ran but output differs';
      this.hmacDetail +=
        `derived (hex): ${hex}\n` +
        `reference (hex): ${REFERENCE_HMAC_HEX}`;
    } catch (e) {
      this.hmacStatus = 'ERROR';
      const be = e as BusinessError;
      this.hmacDetail += `code: ${be.code}\nmessage: ${be.message}\nraw: ${JSON.stringify(e)}`;
    }
  }

  async runPbkdf2Test(iterations: number = REFERENCE_ITERATIONS, algName: string = 'PBKDF2Spec', passwordAsString: boolean = false) {
    this.pbkdf2Status = 'running...';
    this.pbkdf2Detail = '';

    try {
      this.pbkdf2Detail +=
        `device osFullName: ${deviceInfo.osFullName}\n` +
        `device sdkApiVersion: ${deviceInfo.sdkApiVersion}\n\n`;
    } catch (e) {
      this.pbkdf2Detail += `(could not read deviceInfo: ${e})\n\n`;
    }

    const passwordBytes = stringToBytes(REFERENCE_PASSPHRASE);
    const saltBytes = stringToBytes(REFERENCE_SALT);
    this.pbkdf2Detail +=
      `algName: ${algName}\n` +
      `password bytes: ${passwordBytes.length} (${toHex(passwordBytes)})\n` +
      `salt bytes: ${saltBytes.length} (${toHex(saltBytes)})\n` +
      `iterations: ${iterations}, keySize: ${REFERENCE_KEY_SIZE_BITS / 8}\n\n`;

    let kdf: cryptoFramework.Kdf;
    try {
      kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
      this.pbkdf2Detail += 'createKdf: OK\n';
    } catch (e) {
      this.pbkdf2Status = 'ERROR in createKdf';
      const be = e as BusinessError;
      this.pbkdf2Detail += `createKdf FAILED\ncode: ${be.code}\nmessage: ${be.message}\nraw: ${JSON.stringify(e)}`;
      return;
    }

    const params: cryptoFramework.PBKDF2Spec = {
      algName: algName,
      password: passwordAsString ? REFERENCE_PASSPHRASE : passwordBytes,
      salt: saltBytes,
      iterations: iterations,
      keySize: REFERENCE_KEY_SIZE_BITS / 8,
    };
    this.pbkdf2Detail += `password type: ${passwordAsString ? 'string' : 'Uint8Array'}\n`;

    try {
      const secret = await kdf.generateSecret(params);
      const hex = toHex(secret.data).toLowerCase();
      if (iterations === REFERENCE_ITERATIONS && algName === 'PBKDF2Spec') {
        const match = hex === REFERENCE_PBKDF2_HEX;
        this.pbkdf2Status = match ? 'MATCH — compatible with Windows daemon' : 'MISMATCH — do not proceed until fixed';
        this.pbkdf2Detail +=
          `generateSecret: OK\n` +
          `derived (hex): ${hex}\n` +
          `reference (hex): ${REFERENCE_PBKDF2_HEX}`;
      } else {
        // diagnostic run with a non-reference iteration count — no reference
        // value to compare against, just proves whether the call succeeds at all
        this.pbkdf2Status = `OK at iterations=${iterations} (diagnostic only, not comparable to reference)`;
        this.pbkdf2Detail += `generateSecret: OK\nderived (hex): ${hex}`;
      }
    } catch (e) {
      this.pbkdf2Status = 'ERROR in generateSecret';
      const be = e as BusinessError;
      this.pbkdf2Detail += `generateSecret FAILED\ncode: ${be.code}\nmessage: ${be.message}\nraw: ${JSON.stringify(e)}`;
    }
  }

  async runHuksEcdsaTest() {
    this.huksStatus = 'running...';
    try {
      const genProperties: Array<huks.HuksParam> = [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256 },
        {
          tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY,
        },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 },
      ];
      const genOptions: huks.HuksOptions = { properties: genProperties };

      // Ignore "already exists" — this spike re-runs against the same alias.
      try {
        await huks.generateKeyItem(HUKS_KEY_ALIAS, genOptions);
      } catch (genErr) {
        this.huksDetail = `(key generation skipped, may already exist: ${genErr})\n`;
      }

      const sessionProperties: Array<huks.HuksParam> = [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 },
      ];
      const sessionOptions: huks.HuksOptions = { properties: sessionProperties };

      const initResult = await huks.initSession(HUKS_KEY_ALIAS, sessionOptions);
      const handle = initResult.handle;

      const updateOptions: huks.HuksOptions = {
        properties: sessionProperties,
        inData: stringToBytes(SIGN_MESSAGE),
      };
      await huks.updateSession(handle, updateOptions);

      const finishOptions: huks.HuksOptions = { properties: sessionProperties };
      const finishResult = await huks.finishSession(handle, finishOptions);
      const sig = finishResult.outData!;
      const sigHex = toHex(sig);

      // .NET's ECDsa.SignData produces raw IEEE P1363 r||s — exactly 64
      // bytes for P-256. DER/ASN.1 encoding is ~70-72 bytes and starts with
      // 0x30 (SEQUENCE tag). This is the actual unknown the plan flagged —
      // now measured instead of assumed.
      const looksLikeDer = sig.length !== 64 && sig[0] === 0x30;
      const formatNote = sig.length === 64
        ? 'length is 64 — looks like raw r||s, same as .NET default. Should be directly interoperable.'
        : looksLikeDer
          ? `length is ${sig.length} and starts with 0x30 — looks DER/ASN.1-encoded. Needs a DER -> raw r||s conversion step before it will verify against .NET's ECDsa.VerifyData (which expects raw r||s) or vice versa.`
          : `length is ${sig.length}, unrecognized shape — needs manual inspection.`;

      this.huksStatus = 'ran — see format note';
      this.huksDetail +=
        `signature (hex): ${sigHex}\n` +
        `signature length: ${sig.length} bytes\n` +
        `format note: ${formatNote}`;
    } catch (e) {
      this.huksStatus = 'ERROR';
      const be = e as BusinessError;
      this.huksDetail += `code: ${be.code}\nmessage: ${be.message}\nraw: ${JSON.stringify(e)}`;
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('Protocol Compatibility Spike').fontSize(20).fontWeight(FontWeight.Bold)

        Divider()

        Text('1. PBKDF2-SHA256 vs Windows daemon').fontSize(16).fontWeight(FontWeight.Bold)
        Row({ space: 8 }) {
          Button('Run PBKDF2 Test').onClick(() => this.runPbkdf2Test())
          Button('Diagnostic: low iterations').onClick(() => this.runPbkdf2Test(1))
        }
        Row({ space: 8 }) {
          Button('Diagnostic: algName variant').onClick(() => this.runPbkdf2Test(1, 'Pbkdf2ParamsSpec'))
        }
        Row({ space: 8 }) {
          Button('Diagnostic: password as string').onClick(() => this.runPbkdf2Test(1, 'PBKDF2Spec', true))
        }
        Text(`Status: ${this.pbkdf2Status}`)
        Text(this.pbkdf2Detail).fontSize(12)

        Divider()

        Text('2. HUKS ECDSA P-256 signature format').fontSize(16).fontWeight(FontWeight.Bold)
        Button('Run HUKS ECDSA Test').onClick(() => this.runHuksEcdsaTest())
        Text(`Status: ${this.huksStatus}`)
        Text(this.huksDetail).fontSize(12)

        Divider()

        Text('3. HMAC-SHA256 baseline (isolates PBKDF2 failure)').fontSize(16).fontWeight(FontWeight.Bold)
        Button('Run HMAC Test').onClick(() => this.runHmacTest())
        Text(`Status: ${this.hmacStatus}`)
        Text(this.hmacDetail).fontSize(12)

        Divider()

        Text('4. Manual PBKDF2-via-HMAC workaround').fontSize(16).fontWeight(FontWeight.Bold)
        Row({ space: 8 }) {
          Button('Quick check (1000 iter)').onClick(() => this.runManualPbkdf2Test(1000, REFERENCE_PBKDF2_1000_HEX))
          Button('Full (210000 iter)').onClick(() => this.runManualPbkdf2Test(REFERENCE_ITERATIONS, REFERENCE_PBKDF2_HEX))
        }
        Text(`Status: ${this.manualPbkdf2Status}`)
        Text(this.manualPbkdf2Detail).fontSize(12)
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
