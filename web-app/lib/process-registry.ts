import { ChildProcess } from "child_process";

/**
 * Global registry for tracking active Claude CLI processes
 * Enables process termination when sessions are cleaned up
 */
class ProcessRegistry {
  private processes = new Map<string, ChildProcess>();

  /**
   * Register a Claude process for a session
   */
  register(sessionId: string, process: ChildProcess): void {
    console.log(
      `[ProcessRegistry] Registering process ${process.pid} for session ${sessionId}`,
    );
    this.processes.set(sessionId, process);

    // Auto-cleanup on process exit
    process.on("exit", () => {
      console.log(
        `[ProcessRegistry] Process ${process.pid} exited, auto-unregistering`,
      );
      this.processes.delete(sessionId);
    });
  }

  /**
   * Unregister a process for a session
   */
  unregister(sessionId: string): void {
    const process = this.processes.get(sessionId);
    if (process) {
      console.log(
        `[ProcessRegistry] Unregistering process ${process.pid} for session ${sessionId}`,
      );
      this.processes.delete(sessionId);
    }
  }

  /**
   * Get the active process for a session
   */
  getProcess(sessionId: string): ChildProcess | undefined {
    return this.processes.get(sessionId);
  }

  /**
   * Terminate a process gracefully (SIGTERM -> SIGKILL)
   */
  async terminate(sessionId: string): Promise<boolean> {
    const process = this.processes.get(sessionId);
    if (!process) {
      console.log(
        `[ProcessRegistry] No process found for session ${sessionId}`,
      );
      return false;
    }

    // Check if already dead
    if (process.killed || process.exitCode !== null) {
      console.log(
        `[ProcessRegistry] Process ${process.pid} already terminated`,
      );
      this.processes.delete(sessionId);
      return true;
    }

    console.log(
      `[ProcessRegistry] Terminating process ${process.pid} for session ${sessionId}`,
    );

    return new Promise((resolve) => {
      // Send SIGTERM (graceful)
      try {
        process.kill("SIGTERM");
      } catch (err) {
        console.error(
          `[ProcessRegistry] Error sending SIGTERM to ${process.pid}:`,
          err,
        );
        this.processes.delete(sessionId);
        resolve(false);
        return;
      }

      // Wait 2s for graceful exit
      const timeout = setTimeout(() => {
        // Force kill if still alive
        try {
          if (!process.killed && process.exitCode === null) {
            console.log(
              `[ProcessRegistry] Process ${process.pid} did not exit gracefully, sending SIGKILL`,
            );
            process.kill("SIGKILL");
          }
        } catch (err) {
          console.error(
            `[ProcessRegistry] Error sending SIGKILL to ${process.pid}:`,
            err,
          );
        }
        this.processes.delete(sessionId);
        resolve(true);
      }, 2000);

      // Resolve early if process exits
      process.once("exit", () => {
        clearTimeout(timeout);
        console.log(`[ProcessRegistry] Process ${process.pid} terminated`);
        this.processes.delete(sessionId);
        resolve(true);
      });
    });
  }

  /**
   * Terminate all registered processes
   */
  async terminateAll(): Promise<void> {
    console.log(
      `[ProcessRegistry] Terminating all ${this.processes.size} processes`,
    );
    const sessionIds = Array.from(this.processes.keys());
    await Promise.all(sessionIds.map((id) => this.terminate(id)));
  }

  /**
   * Get debug info about registered processes
   */
  getDebugInfo(): Array<{ sessionId: string; pid: number | undefined }> {
    return Array.from(this.processes.entries()).map(
      ([sessionId, process]) => ({
        sessionId,
        pid: process.pid,
      }),
    );
  }
}

// Export singleton instance
export const processRegistry = new ProcessRegistry();
