import { useEffect, useState } from "react";
import { WifiSlash } from "@phosphor-icons/react";
import { Capacitor, type PluginListenerHandle } from "@capacitor/core";
import { Network, type ConnectionStatus } from "@capacitor/network";

export function NativeConnectivityBanner() {
  const [offline, setOffline] = useState(false);

  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return;

    let active = true;
    let listener: PluginListenerHandle | null = null;
    const update = (status: ConnectionStatus) => {
      if (active) setOffline(!status.connected);
    };

    void Network.getStatus().then(update).catch(() => undefined);
    void Network.addListener("networkStatusChange", update)
      .then((handle) => {
        if (!active) {
          void handle.remove();
          return;
        }
        listener = handle;
      })
      .catch(() => undefined);

    return () => {
      active = false;
      if (listener) void listener.remove();
    };
  }, []);

  if (!offline) return null;
  return (
    <div className="native-connectivity-banner" role="status" aria-live="polite">
      <WifiSlash weight="bold" aria-hidden="true" />
      인터넷 연결이 끊겼어요. 작성 중인 내용은 그대로 두고 연결을 기다릴게요.
    </div>
  );
}
