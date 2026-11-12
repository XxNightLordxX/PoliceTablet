-- Every workflow of tests/workflows_full_spec.lua on a city with none of the owner's scripts.

-- Every workflow of tests/workflows_full_spec.lua on a city with none of the owner's scripts.
-- sc-dispatch, sc-ambulance, Renewed-Banking and sc-police are not installed (their exports fail) and the admin sets
-- every Config.Integrations kind to 'none' in Admin UI -> Settings. Each workflow still runs to the same result, with
-- the restart and the drop and reconnect in the middle (docs/dev/WORKFLOWS.md).

_G.CP_WF_STACK = 'none'
return dofile('tests/workflows_full_spec.lua')
