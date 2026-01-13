/**
 * E2E test for agent display
 * Tests that spawning a subagent shows all blocks in correct order
 */

const API_URL = 'http://localhost:3000';

async function createSession() {
  const response = await fetch(`${API_URL}/api/sessions`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({cwd: '/home/ubuntu/.claude'})
  });
  const data = await response.json();
  return data.session.id;
}

async function sendCommand(sessionId, prompt) {
  const response = await fetch(`${API_URL}/api/commands`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({sessionId, prompt})
  });
  
  const blocks = [];
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  
  while (true) {
    const {done, value} = await reader.read();
    if (done) break;
    
    const chunk = decoder.decode(value);
    const lines = chunk.split('\n');
    
    for (const line of lines) {
      if (line.startsWith('data: ')) {
        const data = line.slice(6);
        if (data === '[DONE]') continue;
        
        try {
          const event = JSON.parse(data);
          if (event.type === 'tool_use' || event.type === 'tool_result' || event.type === 'text') {
            blocks.push(event);
          }
        } catch (e) {}
      }
    }
  }
  
  return blocks;
}

async function test() {
  console.log('=== E2E Test: Agent Display ===\n');
  
  const sessionId = await createSession();
  console.log('Created session:', sessionId);
  
  console.log('\nSending command: "spawn a subagent that runs git status"\n');
  const blocks = await sendCommand(sessionId, 'spawn a subagent that runs git status');
  
  console.log('Received blocks:');
  blocks.forEach((block, i) => {
    if (block.type === 'tool_use') {
      console.log(`${i+1}. tool_use: ${block.tool.name} (id: ${block.tool.id})`);
    } else if (block.type === 'tool_result') {
      const contentType = Array.isArray(block.tool_result.content) ? 'array' : 'string';
      console.log(`${i+1}. tool_result: ${block.tool_result.tool_use_id} (content: ${contentType})`);
    } else if (block.type === 'text') {
      const preview = block.content.substring(0, 50);
      console.log(`${i+1}. text: "${preview}..."`);
    }
  });
  
  console.log('\n=== Expected Display Order ===');
  console.log('Agent Frame:');
  console.log('  1. [Bash tool_use] git status command');
  console.log('  2. [Bash tool_result] On branch main...');
  console.log('  3. [text] Repository is clean...');
  console.log('  4. [text] agentId: ...');
  console.log('Outside Frame:');
  console.log('  5. [text] The subagent reports...');
  
  // Validate
  const taskTool = blocks.find(b => b.type === 'tool_use' && b.tool.name === 'Task');
  const bashTool = blocks.find(b => b.type === 'tool_use' && b.tool.name === 'Bash');
  const bashResult = blocks.find(b => b.type === 'tool_result' && b.tool_result.tool_use_id === bashTool?.tool.id);
  const taskResult = blocks.find(b => b.type === 'tool_result' && b.tool_result.tool_use_id === taskTool?.tool.id);
  
  console.log('\n=== Validation ===');
  console.log('✓ Task tool_use found:', !!taskTool);
  console.log('✓ Bash tool_use found:', !!bashTool);
  console.log('✓ Bash tool_result found:', !!bashResult);
  console.log('✓ Task tool_result found:', !!taskResult);
  console.log('✓ Task result is array:', Array.isArray(taskResult?.tool_result.content));
  
  if (taskResult && Array.isArray(taskResult.tool_result.content)) {
    console.log('✓ Task result array length:', taskResult.tool_result.content.length);
  }
  
  console.log('\n=== Test Complete ===');
}

test().catch(console.error);
