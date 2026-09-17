// Protocol compatibility spike (build order step 2 in ../../../../README.md).
// Not a real app screen — a throwaway test harness to prove HarmonyOS crypto
// APIs can interoperate with the Windows daemon's .NET crypto before any
// real app structure gets built on top of unverified assumptions.

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { BusinessError } from '@kit.BasicServicesKit';

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

@Entry
@Component
struct Index {
  @State pbkdf2Status: string = 'not run yet';
  @State pbkdf2Detail: string = '';
  @State huksStatus: string = 'not run yet';
  @State huksDetail: string = '';

  async runPbkdf2Test() {
    this.pbkdf2Status = 'running...';
    try {
      const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
      const params: cryptoFramework.PBKDF2Spec = {
        algName: 'PBKDF2Spec',
        password: stringToBytes(REFERENCE_PASSPHRASE),
        salt: stringToBytes(REFERENCE_SALT),
        iterations: REFERENCE_ITERATIONS,
        keySize: REFERENCE_KEY_SIZE_BITS / 8,
      };
      const secret = await kdf.generateSecret(params);
      const hex = toHex(secret.data).toLowerCase();
      const match = hex === REFERENCE_PBKDF2_HEX;
      this.pbkdf2Status = match ? 'MATCH — compatible with Windows daemon' : 'MISMATCH — do not proceed until fixed';
      this.pbkdf2Detail =
        `derived (hex): ${hex}\n` +
        `reference (hex): ${REFERENCE_PBKDF2_HEX}`;
    } catch (e) {
      this.pbkdf2Status = 'ERROR';
      const be = e as BusinessError;
      this.pbkdf2Detail = `code: ${be.code}\nmessage: ${be.message}\nraw: ${JSON.stringify(e)}`;
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
        Button('Run PBKDF2 Test').onClick(() => this.runPbkdf2Test())
        Text(`Status: ${this.pbkdf2Status}`)
        Text(this.pbkdf2Detail).fontSize(12)

        Divider()

        Text('2. HUKS ECDSA P-256 signature format').fontSize(16).fontWeight(FontWeight.Bold)
        Button('Run HUKS ECDSA Test').onClick(() => this.runHuksEcdsaTest())
        Text(`Status: ${this.huksStatus}`)
        Text(this.huksDetail).fontSize(12)
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
