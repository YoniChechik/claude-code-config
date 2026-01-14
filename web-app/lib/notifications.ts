let originalTitle: string | null = null;

/**
 * Play an audio notification sound
 * Uses Web Audio API to generate a subtle beep
 */
export function playAudioNotification(): void {
  const audioContext = new AudioContext();
  const oscillator = audioContext.createOscillator();
  const gainNode = audioContext.createGain();

  oscillator.connect(gainNode);
  gainNode.connect(audioContext.destination);

  oscillator.frequency.value = 800;
  oscillator.type = "sine";
  gainNode.gain.setValueAtTime(0.3, audioContext.currentTime);
  gainNode.gain.exponentialRampToValueAtTime(
    0.01,
    audioContext.currentTime + 0.5,
  );

  oscillator.start(audioContext.currentTime);
  oscillator.stop(audioContext.currentTime + 0.5);
}

/**
 * Update the page title to indicate completion
 * Saves the original title for later restoration
 */
export function updateTabTitle(message: string = "Done"): void {
  if (originalTitle === null) {
    originalTitle = document.title;
  }
  document.title = `${message} - ${originalTitle}`;
}

/**
 * Clear the tab notification and restore original title
 */
export function clearTabNotification(): void {
  if (originalTitle !== null) {
    document.title = originalTitle;
    originalTitle = null;
  }
}
