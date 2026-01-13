import type { SlashCommand } from "./types";

/**
 * Client-safe autosuggest utilities
 * These functions don't use Node.js modules and can be used in client components
 */

/**
 * Fuzzy score for command matching
 * Enhanced with character-by-character sequential matching
 */
export function fuzzyScore(pattern: string, candidate: string): number {
  const patternLower = pattern.toLowerCase();
  const candidateLower = candidate.toLowerCase();

  // Exact match (highest priority)
  if (patternLower === candidateLower) {
    return 0;
  }

  // Prefix match (second highest priority)
  if (candidateLower.startsWith(patternLower)) {
    return 1;
  }

  // Sequential character matching
  // Example: "cm" matches "commit", "prv" matches "pr-review"
  let patternIndex = 0;
  let candidateIndex = 0;
  let totalDistance = 0;
  let lastMatchPos = -1;

  while (
    patternIndex < patternLower.length &&
    candidateIndex < candidateLower.length
  ) {
    if (patternLower[patternIndex] === candidateLower[candidateIndex]) {
      // Character matched
      const distance = candidateIndex - lastMatchPos - 1;
      totalDistance += distance;
      lastMatchPos = candidateIndex;
      patternIndex++;
    }
    candidateIndex++;
  }

  // If we matched all pattern characters, return score based on distance
  if (patternIndex === patternLower.length) {
    // Score: 2 (base for fuzzy match) + normalized distance (0-10 range)
    // Closer matches get better scores
    const normalizedDistance = Math.min(
      10,
      totalDistance / patternLower.length,
    );
    return 2 + normalizedDistance;
  }

  // No match
  return 999;
}

/**
 * Fuzzy match commands against pattern
 * Ported from fuzzy_match function (lines 284-292)
 */
export function fuzzyMatchCommands(
  pattern: string,
  commands: SlashCommand[],
): SlashCommand[] {
  const scored = commands
    .map((cmd) => ({
      cmd,
      score: fuzzyScore(pattern, cmd.name),
    }))
    .filter(({ score }) => score < 999)
    .sort((a, b) => a.score - b.score);

  return scored.map(({ cmd }) => cmd);
}
