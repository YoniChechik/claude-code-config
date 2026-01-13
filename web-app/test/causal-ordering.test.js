/**
 * E2E test for causal ordering of tool use/result pairs
 * Tests that multiple tool calls maintain proper causal ordering:
 * tool_use_1, tool_result_1, tool_use_2, tool_result_2, tool_use_3, tool_result_3, tool_use_4, tool_result_4
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
          if (event.type === 'tool_use' || event.type === 'tool_result') {
            blocks.push(event);
          }
        } catch (e) {}
      }
    }
  }

  return blocks;
}

async function test() {
  console.log('=== E2E Test: Causal Ordering for Multiple Tool Use/Result Pairs ===\n');

  const sessionId = await createSession();
  console.log('Created session:', sessionId);

  const prompt = 'Read the file /home/ubuntu/.claude/README.md, then list files with ls, then check git status, then show the current directory with pwd';
  console.log(`\nSending command: "${prompt}"\n`);

  const blocks = await sendCommand(sessionId, prompt);

  console.log('=== Received Blocks Order ===');
  blocks.forEach((block, i) => {
    if (block.type === 'tool_use') {
      console.log(`${i+1}. tool_use: ${block.tool.name} (id: ${block.tool.id})`);
    } else if (block.type === 'tool_result') {
      console.log(`${i+1}. tool_result: for tool_use_id ${block.tool_result.tool_use_id}`);
    }
  });

  console.log('\n=== Causal Ordering Validation ===');

  // Extract tool_use blocks
  const toolUses = blocks.filter(b => b.type === 'tool_use');
  console.log(`Found ${toolUses.length} tool_use blocks`);

  // Validate each tool_use is immediately followed by its tool_result
  let allCorrect = true;
  const validationResults = [];

  for (let i = 0; i < toolUses.length; i++) {
    const toolUse = toolUses[i];
    const toolUseId = toolUse.tool.id;
    const toolName = toolUse.tool.name;

    // Find the index of this tool_use in the blocks array
    const toolUseIndex = blocks.findIndex(b =>
      b.type === 'tool_use' && b.tool.id === toolUseId
    );

    // Find the tool_result for this tool_use
    const toolResult = blocks.find(b =>
      b.type === 'tool_result' && b.tool_result.tool_use_id === toolUseId
    );

    if (!toolResult) {
      console.log(`✗ Tool ${i+1} (${toolName}): No matching tool_result found for ${toolUseId}`);
      validationResults.push({
        toolNumber: i + 1,
        toolName,
        toolUseId,
        passed: false,
        reason: 'No matching tool_result'
      });
      allCorrect = false;
      continue;
    }

    const toolResultIndex = blocks.findIndex(b =>
      b.type === 'tool_result' && b.tool_result.tool_use_id === toolUseId
    );

    // Check if tool_result immediately follows tool_use
    const isImmediatelyAfter = toolResultIndex === toolUseIndex + 1;

    // Check if no other tool_use appears between this tool_use and its tool_result
    const blocksBetween = blocks.slice(toolUseIndex + 1, toolResultIndex);
    const hasInterleavedToolUse = blocksBetween.some(b => b.type === 'tool_use');

    const passed = isImmediatelyAfter && !hasInterleavedToolUse;

    if (passed) {
      console.log(`✓ Tool ${i+1} (${toolName}): Correctly ordered at position ${toolUseIndex+1},${toolResultIndex+1}`);
    } else if (!isImmediatelyAfter) {
      console.log(`✗ Tool ${i+1} (${toolName}): tool_result not immediately after tool_use (positions ${toolUseIndex+1},${toolResultIndex+1})`);
    } else if (hasInterleavedToolUse) {
      console.log(`✗ Tool ${i+1} (${toolName}): Other tool_use found between tool_use and tool_result`);
    }

    validationResults.push({
      toolNumber: i + 1,
      toolName,
      toolUseId,
      toolUseIndex: toolUseIndex + 1,
      toolResultIndex: toolResultIndex + 1,
      passed
    });

    allCorrect = allCorrect && passed;
  }

  console.log('\n=== Expected Pattern ===');
  console.log('tool_use_1, tool_result_1, tool_use_2, tool_result_2, tool_use_3, tool_result_3, tool_use_4, tool_result_4');

  console.log('\n=== Actual Pattern ===');
  const pattern = blocks.map(b => {
    if (b.type === 'tool_use') {
      const toolNum = toolUses.findIndex(tu => tu.tool.id === b.tool.id) + 1;
      return `tool_use_${toolNum}`;
    } else {
      const toolUseId = b.tool_result.tool_use_id;
      const toolNum = toolUses.findIndex(tu => tu.tool.id === toolUseId) + 1;
      return `tool_result_${toolNum}`;
    }
  }).join(', ');
  console.log(pattern);

  console.log('\n=== Summary ===');
  console.log(`Total tool calls: ${toolUses.length}`);
  console.log(`Causal ordering: ${allCorrect ? '✓ CORRECT' : '✗ INCORRECT'}`);

  if (allCorrect) {
    console.log('\n✓✓✓ TEST PASSED ✓✓✓');
  } else {
    console.log('\n✗✗✗ TEST FAILED ✗✗✗');
  }

  console.log('\n=== Test Complete ===');

  return allCorrect;
}

test()
  .then(passed => process.exit(passed ? 0 : 1))
  .catch(err => {
    console.error('Test error:', err);
    process.exit(1);
  });
