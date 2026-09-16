// STEP 4:
// Generate (or load, if one already exists on disk) this device's permanent
// keypair — its identity. This is the foundation pairing/trust/signing all
// build on.

using System.Security.Cryptography;

namespace ClipboardDaemon.Identity;

public class DeviceIdentity
{
    private ECDsa key = ECDsa.Create();
    // TODO
    public DeviceIdentity() : this(""){}
    public DeviceIdentity(string deviceID)
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string key_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"identity{deviceID}.key");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(key_path))
        {
            key.ImportPkcs8PrivateKey(File.ReadAllBytes(key_path), out _);
        }
        else
        {
            key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            File.WriteAllBytes(key_path, key.ExportPkcs8PrivateKey());
        }
    }
    /*
    return the base64 publickey
    */
    public string GetPublicKey(){
        return Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());
    }
    public byte[] SignData(byte[] data)
    {
        return key.SignData(data, HashAlgorithmName.SHA256);
    }
}
