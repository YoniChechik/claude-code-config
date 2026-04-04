# CORE GUIDELINES

- Be concise. No unnecessary detail.
- ALWAYS USE TASKS! EVEN FOR SIMPLE 1 BLOCK TASKS! AFTER READING SKILL ADD ALL NEW TASKS TO TASK LIST IMMEDIATELY!
- COMMIT AND PUSH FREQUENTLY!
- NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.
- THERE IS NO SUCH THING AS PRE_EXITING ERRORS- IF YOU FIND AN ERROR YOU FIX IT IMMEDIATELY!
- NEVER use `EnterPlanMode`/`ExitPlanMode` tools. Use the `/plan` skill instead when planning is needed.
- When working on feature- make sure you used `/create-clone` or `/cd-permanent` to work inside the clone. NEVER work directly in the base repo directory.
- make sure each feature works according to the feature development workflow outlined in the `feature-workflow.md` document.
- NEVER use `sleep` to wait for something to happen. Use a polling for-loop with short intervals instead for faster responses.

