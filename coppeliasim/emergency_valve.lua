-- Child script on /Distillation_Column in reactor_simulation.ttt (5 monitored locations).
-- Reference copy only: CoppeliaSim runs the copy embedded in the scene, so
-- paste changes into the scene's script editor to apply them.

sim = require('sim')

function sysCall_init()
    feedValve       = sim.getObject('/Feed_Pipe/Feed_Valve')
    distillateValve = sim.getObject('/Distillate_Pipe/Distillate_Valve')
    bottomsValve    = sim.getObject('/Bottoms_Pipe/Bottoms_Valve')
    columnBottomValve = sim.getObject('/Column_Bottom_Pipe/Column_Bottom_Valve')
    columnTopValve    = sim.getObject('/Column_Top_Pipe/Column_Top_Valve')

    -- One shared driver for the whole column - a real upset (e.g. reboiler
    -- duty increasing) affects every pipe at once, same root cause
    boilUpRate = 0.0
    boilUpTarget = 0.0
    pressureSmoothed = {feed_pipeline = 30.0, distillate_output = 42.0, bottoms_output = 48.0,
                        column_bottom = 49.0, column_top = 40.0}

    -- Per-location baselines/ranges (F, PSI, gpm). column_bottom runs hottest
    -- (upstream of bottoms_output), column_top runs cooler than distillate_output
    -- (upstream of the condenser). All 5 share boilUpRate, so demo_spike drives
    -- every location toward its own limit at once
    locations = {
        feed_pipeline = {
            valve = feedValve,
            baseTemp = 90.0,  tempRange = 15.0,
            basePress = 30.0, pressRange = 8.0,
            baseFlow = 2.0,   flowRange = 0.8,
        },
        distillate_output = {
            valve = distillateValve,
            baseTemp = 140.0, tempRange = 20.0,
            basePress = 42.0, pressRange = 12.0,
            baseFlow = 1.8,   flowRange = 1.2,
        },
        bottoms_output = {
            valve = bottomsValve,
            baseTemp = 165.0, tempRange = 22.0,
            basePress = 48.0, pressRange = 14.0,
            baseFlow = 2.2,   flowRange = 1.0,
        },
        column_bottom = {
            valve = columnBottomValve,
            baseTemp = 170.0, tempRange = 22.0,
            basePress = 49.0, pressRange = 14.0,
            baseFlow = 2.2,   flowRange = 1.0,
        },
        column_top = {
            valve = columnTopValve,
            baseTemp = 135.0, tempRange = 20.0,
            basePress = 40.0, pressRange = 12.0,
            baseFlow = 1.8,   flowRange = 1.2,
        }
    }

    updateInterval = 20  -- seconds
    lastUpdateTime = 0
    math.randomseed(os.time())
end

function sysCall_actuation()
    local t = sim.getSystemTime()

    -- Each valve moves only on its own location's shutdown signal
    for name, loc in pairs(locations) do
        local shutdownSignal = sim.getFloatSignal(name .. '_valve_shutdown')
        loc.shutDown = shutdownSignal and shutdownSignal > 0.5
        sim.setJointPosition(loc.valve, loc.shutDown and 1.57 or 0.0)
    end

    -- Shared spike, consumed once, same as the single-pipe version
    local spikeRequested = sim.getFloatSignal('demo_spike')
    if spikeRequested and spikeRequested > 0.5 then
        sim.clearFloatSignal('demo_spike')
        boilUpTarget = 1.0
    elseif t - lastUpdateTime >= updateInterval then
        lastUpdateTime = t
        boilUpTarget = math.max(0, math.min(1,
            boilUpTarget + (math.random() * 0.3 - 0.15)))
    end

    boilUpRate = boilUpRate + (boilUpTarget - boilUpRate) * 0.3

    for name, loc in pairs(locations) do
        if not loc.shutDown then
            local temp = loc.baseTemp + boilUpRate * loc.tempRange + (math.random() * 2 - 1)

            local pressureTarget = loc.basePress + boilUpRate * loc.pressRange
            pressureSmoothed[name] = pressureSmoothed[name]
                                       + (pressureTarget - pressureSmoothed[name]) * 0.15
            local press = pressureSmoothed[name] + (math.random() * 1 - 0.5)

            local flow = loc.baseFlow + boilUpRate * loc.flowRange + (math.random() * 0.6 - 0.3)

            sim.setFloatSignal(name .. '_temperature', temp)
            sim.setFloatSignal(name .. '_pressure', press)
            sim.setFloatSignal(name .. '_flow_rate', flow)
        end
        -- if shut down, signals simply hold at their last value
    end
end
