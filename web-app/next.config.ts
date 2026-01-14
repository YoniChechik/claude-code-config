import type { NextConfig } from "next";
import { execSync } from "child_process";

const getBuildCommit = () => {
  try {
    return execSync("git rev-parse HEAD", {
      encoding: "utf-8",
    }).trim();
  } catch {
    return "unknown";
  }
};

const nextConfig: NextConfig = {
  env: {
    BUILD_COMMIT: getBuildCommit(),
  },
};

export default nextConfig;
