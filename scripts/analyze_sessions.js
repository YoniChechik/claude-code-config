#!/usr/bin/env node
/**
 * Script to analyze session files and extract richer metadata
 * This helps identify what additional information could be shown in the session picker
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

function analyzeSession(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf-8');
    const lines = content.trim().split('\n').filter(line => line.trim());

    if (lines.length === 0) {
      return null;
    }

    const parsedLines = lines.map(line => JSON.parse(line));

    // Get basic metadata
    const firstLine = parsedLines[0];
    const lastLine = parsedLines[parsedLines.length - 1];

    // Extract user and assistant messages
    const userMessages = parsedLines.filter(l => l.type === 'user' && l.message);
    const assistantMessages = parsedLines.filter(l => l.type === 'assistant' && l.message);

    // Get first user message
    let firstUserMessage = '';
    if (userMessages.length > 0) {
      const content = userMessages[0].message.content;
      if (typeof content === 'string') {
        firstUserMessage = content;
      } else if (Array.isArray(content)) {
        const textBlock = content.find(b => b.type === 'text');
        if (textBlock && textBlock.text) {
          firstUserMessage = textBlock.text;
        }
      }
    }

    // Get last user message
    let lastUserMessage = '';
    if (userMessages.length > 0) {
      const content = userMessages[userMessages.length - 1].message.content;
      if (typeof content === 'string') {
        lastUserMessage = content;
      } else if (Array.isArray(content)) {
        const textBlock = content.find(b => b.type === 'text');
        if (textBlock && textBlock.text) {
          lastUserMessage = textBlock.text;
        }
      }
    }

    // Count tool uses by type
    const toolUses = {};
    assistantMessages.forEach(msg => {
      if (msg.message && Array.isArray(msg.message.content)) {
        msg.message.content.forEach(block => {
          if (block.type === 'tool_use') {
            toolUses[block.name] = (toolUses[block.name] || 0) + 1;
          }
        });
      }
    });

    // Count text blocks in assistant messages
    let totalTextLength = 0;
    assistantMessages.forEach(msg => {
      if (msg.message && Array.isArray(msg.message.content)) {
        msg.message.content.forEach(block => {
          if (block.type === 'text' && block.text) {
            totalTextLength += block.text.length;
          }
        });
      }
    });

    // Extract unique cwds mentioned
    const cwds = new Set();
    parsedLines.forEach(line => {
      if (line.cwd) {
        cwds.add(line.cwd);
      }
    });

    return {
      filePath: path.basename(filePath),
      sessionId: firstLine.sessionId,
      totalLines: lines.length,
      userMessages: userMessages.length,
      assistantMessages: assistantMessages.length,
      firstUserMessage: firstUserMessage.substring(0, 100),
      lastUserMessage: lastUserMessage.substring(0, 100),
      toolUses,
      totalTextLength,
      uniqueCwds: Array.from(cwds),
      createdAt: firstLine.timestamp,
      lastActivityAt: lastLine.timestamp,
    };
  } catch (error) {
    console.error(`Error analyzing ${filePath}:`, error.message);
    return null;
  }
}

function main() {
  const projectsDir = path.join(os.homedir(), '.claude', 'projects');

  console.log('Analyzing session files...\n');

  // Find all session files
  const allFiles = [];
  const dirs = fs.readdirSync(projectsDir);

  for (const dir of dirs) {
    if (dir.startsWith('.')) continue;

    const dirPath = path.join(projectsDir, dir);
    const stats = fs.statSync(dirPath);
    if (!stats.isDirectory()) continue;

    const files = fs.readdirSync(dirPath);
    for (const file of files) {
      if (file.endsWith('.jsonl') && !file.includes('subagent')) {
        allFiles.push(path.join(dirPath, file));
      }
    }
  }

  // Analyze recent 10 sessions
  const filesWithMtime = allFiles.map(f => ({
    path: f,
    mtime: fs.statSync(f).mtime
  }));

  filesWithMtime.sort((a, b) => b.mtime - a.mtime);
  const recentFiles = filesWithMtime.slice(0, 10).map(f => f.path);

  console.log(`Found ${allFiles.length} total sessions, analyzing 10 most recent:\n`);

  const analyses = recentFiles
    .map(analyzeSession)
    .filter(a => a !== null);

  // Print summary
  analyses.forEach((analysis, idx) => {
    console.log(`\n=== Session ${idx + 1} ===`);
    console.log(`File: ${analysis.filePath}`);
    console.log(`Session ID: ${analysis.sessionId}`);
    console.log(`Created: ${new Date(analysis.createdAt).toLocaleString()}`);
    console.log(`Last activity: ${new Date(analysis.lastActivityAt).toLocaleString()}`);
    console.log(`Total lines: ${analysis.totalLines}`);
    console.log(`User messages: ${analysis.userMessages}`);
    console.log(`Assistant messages: ${analysis.assistantMessages}`);
    console.log(`Working directories: ${analysis.uniqueCwds.join(', ')}`);
    console.log(`First user message: "${analysis.firstUserMessage}${analysis.firstUserMessage.length >= 100 ? '...' : ''}"`);
    console.log(`Last user message: "${analysis.lastUserMessage}${analysis.lastUserMessage.length >= 100 ? '...' : ''}"`);
    console.log(`Tool usage:`, JSON.stringify(analysis.toolUses, null, 2));
    console.log(`Total assistant text length: ${analysis.totalTextLength} chars`);
  });

  // Print insights
  console.log('\n\n=== INSIGHTS ===');
  console.log('\nCurrent modal shows:');
  console.log('  - CWD');
  console.log('  - Message count');
  console.log('  - Last message preview (truncated to 50 chars)');
  console.log('  - Time ago');

  console.log('\nAdditional data available:');
  console.log('  - First user message (often describes the task/goal)');
  console.log('  - Tool usage patterns (shows what was done: Read, Write, Bash, etc.)');
  console.log('  - Session duration (time between first and last activity)');
  console.log('  - User vs assistant message ratio');
  console.log('  - Multiple CWDs if directory changed during session');
}

main();
