-- FIN11: every workflow of tests/workflows_full_spec.lua with only Config.Integrations.banking set to none.

-- FIN11: every workflow of tests/workflows_full_spec.lua with only Config.Integrations.banking set to none.
-- The owner's scripts all run (sc-dispatch, sc-ambulance, Renewed-Banking, sc-police) and the admin sets just this one
-- kind to 'none' in Admin UI -> Settings -> Other scripts: the other three keep the owner's script, and every workflow
-- still runs to the same result (docs/dev/WORKFLOWS.md). tests/workflows_none_spec.lua sets all four at once.

_G.CP_WF_STACK = 'none:banking'
return dofile('tests/workflows_full_spec.lua')
