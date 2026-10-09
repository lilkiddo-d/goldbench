import { deployment } from "@/config/deployments";
import { DEPLOYMENT_KEY } from "@/config/env";

export function DeploymentBanner() {
  if (deployment.unknownKey) {
    return (
      <div className="border-b border-bad/40 bg-bad/10 px-4 py-2 text-center text-sm text-bad">
        Unknown deployment &quot;{DEPLOYMENT_KEY}&quot; (no src/config/deployments.{DEPLOYMENT_KEY}.json registered). Falling
        back to &quot;4663&quot;.
      </div>
    );
  }
  if (!deployment.placeholder) return null;
  return (
    <div className="border-b border-gold-700/50 bg-gold-700/10 px-4 py-2 text-center text-sm text-gold-300">
      Not deployed yet — contracts for deployment &quot;{deployment.key}&quot; have not been published. Figures below are
      placeholders.
    </div>
  );
}
