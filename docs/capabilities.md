| Capabilities                          | Available     |
|---------------------------------------|---------------|
| supportsConfigurationDoneRequest      | Yes           |
| supportsFunctionBreakpoints           | Yes           |
| supportsConditionalBreakpoints        | Yes           |
| supportsHitConditionalBreakpoints     | Yes           |
| supportsEvaluateForHovers             | Yes           |
| exceptionBreakpointFilters            | Yes           |
| supportsStepBack                      | No (LuaDebug) |
| supportsSetVariable                   | Yes           |
| supportsRestartFrame                  | Yes           |
| supportsGotoTargetsRequest            | No (LuaDebug) |
| supportsStepInTargetsRequest          | No (LuaDebug) |
| supportsCompletionsRequest            | No (LuaDebug) |
| completionTriggerCharacters           | No (LuaDebug) |
| supportsModulesRequest                | No (VSCode)   |
| additionalModuleColumns               | No (VSCode)   |
| supportedChecksumAlgorithms           | No (VSCode)   |
| supportsRestartRequest                | Yes           |
| supportsExceptionOptions              | No (VSCode)   |
| supportsValueFormattingOptions        | No (VSCode)   |
| supportsExceptionInfoRequest          | Yes           |
| supportTerminateDebuggee              | Yes           |
| supportSuspendDebuggee                | Yes           |
| supportsDelayedStackTraceLoading      | Yes           |
| supportsLoadedSourcesRequest          | Yes           |
| supportsLogPoints                     | Yes           |
| supportsTerminateThreadsRequest       | Yes           |
| supportsSetExpression                 | Yes           |
| supportsTerminateRequest              | Yes           |
| supportsDataBreakpoints               | No (LuaDebug) |
| supportsReadMemoryRequest             | Yes           |
| supportsWriteMemoryRequest            | Yes           |
| supportsDisassembleRequest            | Yes           |
| supportsCancelRequest                 | No (LuaDebug) |
| supportsBreakpointLocationsRequest    | No (LuaDebug) |
| supportsClipboardContext              | Yes           |
| supportsSteppingGranularity           | No (VSCode)   |
| supportsInstructionBreakpoints        | Yes           |
| supportsExceptionFilterOptions        | Yes           |
| supportsSingleThreadExecutionRequests | No (VSCode)   |
| supportsDataBreakpointBytes           | No (LuaDebug) |
| breakpointModes                       | No (LuaDebug) |
| supportsANSIStyling                   | Yes           |

| Capabilities (Client)               | Available     |
|-------------------------------------|---------------|
| supportsVariableType                | Yes           |
| supportsVariablePaging              | Yes           |
| supportsRunInTerminalRequest        | Yes           |
| supportsMemoryReferences            | Yes           |
| supportsProgressReporting           | No (LuaDebug) |
| supportsInvalidatedEvent            | Yes           |
| supportsMemoryEvent                 | No (VSCode)   |
| supportsArgsCanBeInterpretedByShell | Yes           |
| supportsStartDebuggingRequest       | No (VSCode)   |
| supportsANSIStyling                 | Yes           |

* Yes: already supported.
* No (LuaDebug): not implemented in LuaDebug.
* No (VSCode): not implemented in VSCode.
