// HarmonyOS apps are sandboxed and have no equivalent of Windows's
// TailscaleHelper.cs (which shells out to `tailscale ip -4` to learn this
// device's own tailnet address) - there's no API to ask another installed
// app for its state, and Tailscale doesn't expose one. This is the
// phone-side substitute: the user copies their tailnet IP from the
// Tailscale app once and pastes it in here, and it's used exactly the way
// Windows uses its auto-detected one - carried in the LAN beacon (so a
// trusted peer can cache it for later off-LAN reconnects, see SyncManager's
// off-LAN reconnect loop and Discovery.ets's ownAddress) and in the QR/
// manual pairing payload (see Index.ets's refreshPairingPayload).

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREFERENCES_NAME = 'cliplink_device_settings';
const TAILSCALE_IP_KEY = 'tailscale_ip';

export class DeviceSettings {
  private async getPrefs(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, PREFERENCES_NAME);
  }

  async getTailscaleIp(context: common.UIAbilityContext): Promise<string> {
    const prefs = await this.getPrefs(context);
    return prefs.getSync(TAILSCALE_IP_KEY, '') as string;
  }

  async setTailscaleIp(context: common.UIAbilityContext, ip: string): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(TAILSCALE_IP_KEY, ip.trim());
    await prefs.flush();
  }
}
