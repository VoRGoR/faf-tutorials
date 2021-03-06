local ScenarioFramework = import('/lua/scenarioframework.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

TutorialManager = Class {
    -- This function just sets up variables local to the new TutorialManager Instance
    Create = function(self)
        self.Trash = TrashBag()

        self.AIBrain = false
        self.strArmy = false
        self.Active = false
        self.Initialized = false

        self.Orders = {
            ACU = {},
            Engineers = {},
            Factories = {},
            Units = {},
        }
        self.Expansions = {}

        self.Units = {
            ACU = nil,
            AttackGroups = {},
            Engineers = {},
            Factories = {
                Land = {},
                Air = {},
                Naval = {},
                Gate = {},
            },
        }

        self.StringsFile = false
        self.VoiceOvers = {}

        self.TriggerNumber = 1
    end,

    -- Starts the build order
    -- Spawn ACU, assign orders. 
    -- Starts threads for monitoring built units
    Initialize = function(self, strArmy)
        self.Active = true
        if self.Initialized then
            error('*AI ERROR: TutorialManager has already been initialized', 2)
        end
        self.Initialized = true

        if not strArmy then
            strArmy = 'Tutorial_AI'
        end

        self.strArmy = strArmy
        self.AIBrain = GetArmyBrain(strArmy)
        self.AIBrain:PBMRemoveBuildLocation( false, 'MAIN' ) -- remove main since we dont use it in ops much -- TODO: might not need this line at all, no platoons currently

        self:SpawnACU() -- Spawn ACU, assign orders to it

        self:SetVoiceOverTriggers() -- Set triggers for VoiceOvers

        self:ForkThread(self.NewFactoriesMonitor) -- Start a thread to manage newly built factories
        self:ForkThread(self.NewEngineersMonitor) -- Start a thread to manage newly built engineers
        self:ForkThread(self.NewUnitsMonitor) -- Start a thread to manage newly built units

        self:PlayeVoiceOver('Start')
    end,

    BaseActive = function(self, val)
        self.Active = val
    end,

    SpawnACU = function(self)
        self.Units.ACU = ScenarioFramework.SpawnCommander(self.strArmy, 'ACU', 'Warp', 'ACU')
        self:ForkThread(self.AssignEngineerOrders, self.Units.ACU, nil, true) -- Orders for ACU
    end,

    -- Auto trashbags all threads on a base manager
    ForkThread = function(self, fn, ...)
        if fn then
            local thread = ForkThread(fn, self, unpack(arg))
            self.Trash:Add(thread)
            return thread
        else
            return nil
        end
    end,

    WaitThread = function(self, group, data)
        local locked = true

        Unlock = function()
            locked = false
        end

        ScenarioFramework.CreateArmyStatTrigger(Unlock, self.AIBrain, 'Trigger' .. self.TriggerNumber, 
            {{StatType = data[1], CompareType = 'GreaterThanOrEqual', Value = data[2], Category = data[3]}})
        self.TriggerNumber = self.TriggerNumber + 1

        while locked do
            WaitSeconds(1)
        end
        IssueClearCommands(group)
        IssueClearFactoryCommands(group)
    end,

    SetVoiceOvers = function(self, file, voTable)
        self.StringsFile = file
        self.VoiceOvers = voTable
    end,

    -- This needs to be done after army brain is set, Initialize function is called
    SetVoiceOverTriggers = function(self)
        for voName, data in self.VoiceOvers do
            if type(data) == 'table' then
                ForkThread(
                    function(voName, data)
                        local locked = true
                        local name = 'Trigger' .. self.TriggerNumber
                        local cb = data[4]

                        Unlock = function()
                            locked = false
                        end

                        ScenarioFramework.CreateArmyStatTrigger(Unlock, self.AIBrain, name, 
                            {{StatType = data[1], CompareType = 'GreaterThanOrEqual', Value = data[2], Category = data[3]}})
                        self.TriggerNumber = self.TriggerNumber + 1

                        self.VoiceOvers[voName] = name

                        while locked do
                            WaitSeconds(1)
                        end

                        self:PlayeVoiceOver(name, cb)
                    end, voName, data
                )
            end
        end
    end,

    PlayeVoiceOver = function(self, string, cb)
        for voName, nType in self.VoiceOvers do
            if nType == string then
                ScenarioFramework.Dialogue(self.StringsFile[voName], cb, true)
            end
        end
    end,

    ------------
    -- Engineers
    ------------
    SetEngineersOrders = function(self, data)
        for units, tblOrders in data do
            self.Orders[units] = tblOrders
        end
    end,

    GetACU = function(self)
        return self.Units.ACU
    end,

    GetEnginner = function(self, number)
        return self.Units.Engineers[number]
    end,

    GetNumberOfEngineers = function(self)
        return table.getn(self.Units.Engineers)
    end,

    -- Main engineer thread, checks for newly built engineers, assign orders to them
    NewEngineersMonitor = function(self)
        while self.Active do
            local units = self.AIBrain:GetListOfUnits(categories.ENGINEER - categories.COMMAND, false, true) -- NeedToBeIdle, NeedToBeBuilt

            for _, eng in units do
                if not eng.Used and eng:GetFractionComplete() == 1 then -- Need to check if unit is completed as well since the above ^^ doesn't work
                    -- Register the factory in the manager table
                    table.insert(self.Units.Engineers, eng)
                    local num = self:GetNumberOfEngineers()

                    eng:SetCustomName(num)

                    self:PlayeVoiceOver('Engineer' .. num)

                    -- Assign orders
                    self:ForkThread(self.AssignEngineerOrders, eng, num)

                    eng.Used = true
                end
            end
            WaitSeconds(1)
        end
    end,

    AssignEngineerOrders = function(self, engineer, num, isACU)
        local tblOrders = {}
        if isACU then
            tblOrders = self.Orders.ACU
        else
            tblOrders = self.Orders.Engineers[num]
        end

        if not tblOrders then
            LOG('No oders for: Engineer ' .. num)
            return
        end

        -- ACU starts building right away
        if not isACU then
            WaitSeconds(3)

            self:IssueGroupStopClearCommands({engineer})
        end

        for _, order in tblOrders do
            for action, data in order do
                if action == 'assist' then
                    self:IssueGroupAssist({engineer}, data)
                elseif action == 'attackmove' then
                    self:IssueGroupAttackMove({engineer}, data)
                elseif action == 'build' then
                    if type(data) == 'string' then
                        self:EngineerBuildGroup(engineer, data)
                    elseif type(data) == 'table' then
                        self:EngineerBuildUnit(engineer, unpack(data))
                    end
                elseif action == 'move' then
                    self:IssueGroupMove({engineer}, data)
                elseif action == 'patrol' then
                    self:IssueGroupPatrol({engineer}, data)
                elseif action == 'reclaim' then
                    self:EngineerReclaim(engineer, data)
                elseif action == 'wait' then
                    self:WaitThread({engineer}, data)
                else
                    WARN('*TUTORIAL MANAGER ERROR: AssignEngineerOrders, unknown action type: "' .. action .. '". Supported types: assist, attackmove, build, move, patrol, reclaim, wait')
                end
            end
        end
    end,

    --- Function for an engineer to reclaim based on info in data
    -- data is a table that contains 4 possible values
    -- - minMass : minimum amount of mass a prop needs for it to be reclaimed
    -- - area : a square area containing the to-be-reclaimed props
    -- - simpleChainFigure : chain of the edges for a simple figure containing the to-be-reclaimed props (either use area or simpleChainFigure)
    -- - moveChain : chain of positions the engineer will move to, it will reclaim props in range of these positions
    EngineerReclaim = function(self, engineer, data)
        if not data then
            return
        end
        
        local MassFilter = function(p)
                return not data.minMass or data.minMass <= p.MaxMassReclaim * p.ReclaimLeft
            end
        
        local propsToReclaim
        --area
        if data.area then
            propsToReclaim = GetReclaimablesInRect(ScenarioUtils.AreaToRect(data.area))
        end
        
        --simpleChainFigure
        if data.simpleChainFigure then
            propsToReclaim = {}
            local positions = ScenarioUtils.ChainToPositions(data.simpleChainFigure)
            
            -- make a square around the figure, to narrow down the props that need to be checked later
            local encapsulatingRect = {}
            for _,pos in positions do
                if not encapsulatingRect[1] or encapsulatingRect[1] > pos[1] then
                    encapsulatingRect[1] = pos[1]
                end
                if not encapsulatingRect[2] or encapsulatingRect[2] > pos[3] then
                    encapsulatingRect[2] = pos[3]
                end
                if not encapsulatingRect[3] or encapsulatingRect[3] < pos[1] then
                    encapsulatingRect[3] = pos[1]
                end
                if not encapsulatingRect[4] or encapsulatingRect[4] < pos[3] then
                    encapsulatingRect[4] = pos[3]
                end
            end
            local props = GetReclaimablesInRect(Rect(encapsulatingRect[1],encapsulatingRect[2],encapsulatingRect[3],encapsulatingRect[4]))
            
            local moduloFunc = function(value, divider)
                    return value - math.floor(value / divider) * divider
                end
            
            
            --only use props inside figure (uses a Ray casting algorithm)
            for _,prop in props do
                local line = prop:GetPosition()[1] -- the horizontal ray
                local propZ = prop:GetPosition()[3] -- vertical position for calculation relative position of intersections and props
                local before = 0 -- # intersections with figure left of prop
                local after = 0 -- # intersections with figure right of prop
                for i=1,table.getn(positions) do -- loop over each edge of the figure
                    local p1 = positions[i]
                    
                    local modulo = moduloFunc(i, table.getn(positions))
                    local p2 = positions[modulo + 1]
                    local intersection = (p1[1] < line and p2[1] > line) or (p1[1] > line and p2[1] < line)
                    
                    if intersection then
                        local z = ((line - p2[1]) / (p1[1] - p2[1]) * (p1[3] - p2[3])) + p2[3]
                        if z < propZ then
                            before = before + 1
                        else
                            after = after + 1
                        end
                    end
                end
                if moduloFunc(before, 2) == 0 or  moduloFunc(after, 2) == 0 then
                    continue
                end
                table.insert(propsToReclaim, prop)
            end
        end
        
        if data.moveChain then
            local positions = ScenarioUtils.ChainToPositions(data.moveChain)
            local range = engineer:GetBlueprint().Economy.MaxBuildDistance + 2 --magic? not sure why MaxBuildDistance is too short
            for _,position in positions do
                IssueMove({engineer}, position)
                local propsInRange = propsToReclaim or GetReclaimablesInRect(Rect(position[1] - range,position[3] - range,position[1] + range,position[3] + range))
                propsInRange = table.filter(propsInRange, MassFilter)
                for _,prop in propsInRange do
                    local propPos = prop:GetPosition()
                    local dist = VDist2(position[1],position[3], propPos[1], propPos[3])
                    if dist > range then
                        continue
                    end
                    IssueReclaim({engineer}, prop)
                end
            end
        else
            propsToReclaim = table.filter(propsToReclaim, MassFilter)
            for k, prop in propsToReclaim do
                IssueReclaim({engineer}, prop)
            end
        end
    end,

    EngineerBuildUnit = function(self, engineer, ...)
        local aiBrain = self.AIBrain

        for k,v in arg do
            if k != 'n' then
                local unitData = ScenarioUtils.FindUnit(v, Scenario.Armies[self.strArmy].Units)
                if not unitData then
                    WARN('*WARNING: Invalid unit name ' .. v)
                end

                -- Move before building
                if Scenario.MasterChain._MASTERCHAIN_.Markers[v] then
                    IssueMove({engineer}, Scenario.MasterChain._MASTERCHAIN_.Markers[v].position)
                end
                IssueBuildMobile({engineer}, unitData.Position, unitData.type, {})
            end
        end
    end,

    EngineerBuildGroup = function(self, engineer, group)
        local aiBrain = self.AIBrain
        local tblData = ScenarioUtils.FindUnitGroup(group, Scenario.Armies[self.strArmy].Units)

        if not tblData then
            WARN('*WARNING: No groupd named: ' .. group)
        end

        units = {}
        for idx, unitData in tblData.Units do
            local _,_,num = string.find(idx, "^(%d+)")
            num = tonumber(num)
            units[num] = unitData

            -- Add move position
            if Scenario.MasterChain._MASTERCHAIN_.Markers[idx] then
                units[num].move = Scenario.MasterChain._MASTERCHAIN_.Markers[idx].position
            end
        end

        for _, unitData in units do
            if unitData.move then
                IssueMove({engineer}, unitData.move)
            end
            IssueBuildMobile({engineer}, unitData.Position, unitData.type, {})
        end
    end,

    ------------
    -- Factories
    ------------
    SetFactoriesQueue = function(self, data)
        self.Orders.Factories = data
    end,

    GetFactory = function(self, type, num)
        return self.Units.Factories[type][num]
    end,

    GetFactoryType = function(self, factory)
        local type = 'Air'
        if EntityCategoryContains(categories.LAND, factory) then
            type = 'Land' 
        elseif EntityCategoryContains(categories.NAVAL, factory) then
            type = 'Naval' 
        elseif EntityCategoryContains(categories.GATE, factory) then
            type = 'Gate' 
        end
        return type
    end,

    GetFactoryNumber = function(self, factory)
        local number = 0
        local type = self:GetFactoryType(factory)
        for num, fac in self.Units.Factories[type] do
            if fac == factory then
                number = num
                break
            end
        end
        return num
    end,

    GetNumOfFactories = function(self, type)
        return table.getn(self.Units.Factories[type])
    end,

    -- Main factory thread, checks for newly built factories, assign orders to them
    NewFactoriesMonitor = function(self)
        while self.Active do
            local units = self.AIBrain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, true, true) -- NeedToBeIdle, includeUnfinished

            for _, fac in units do
                if not fac.Used then
                    -- Register the factory in the manager table
                    local type = self:GetFactoryType(fac)
                    table.insert(self.Units.Factories[type], fac)
                    local num = self:GetNumOfFactories(type)

                    fac:SetCustomName(type .. num)

                    self:PlayeVoiceOver(type .. 'Factory' .. num)

                    -- Assign orders
                    self:ForkThread(self.AssignFactoryOrders, fac, type, num)

                    fac.Used = true
                end
            end
            WaitSeconds(1)
        end
    end,

    AssignFactoryOrders = function(self, factory, type, num)
        local tblOrders = self.Orders.Factories[type][num]
        local lastOrder = {}

        if not tblOrders then
            LOG('No orders for: ' .. type .. ' Factory ' .. num)
            return
        end

        WaitSeconds(3) -- Wait few seconds after factory is started, as player would do before setting build queue

        IssueClearFactoryCommands({factory})
        for _, order in tblOrders do
            lastOrder = order

            for action, data in order do
                if action == 'wait' then -- First, check if we should wait until the previous order is done
                    self:SetFactoryWait(factory)
                elseif action == 'RallyPoint' then -- Second, check if rally point is changing
                    self:SetFactoryRallyPoint(factory, data)
                elseif action == 'build' then
                    self:SetFactoryBuildQueue(factory, data)
                elseif action == 'assist' then
                    self:SetFactoryAssist(factory, data)
                elseif action == 'patrol' then
                    self:SetFactoryPatrol(factory, data)
                elseif action == 'RepeatBuild' then
                    self:SetFactoryRepeatBuild(factory, data)
                else
                    WARN('*TUTORIAL MANAGER ERROR: AssignFactoryOrders, unknown action type: "' .. action .. '". Supported types: wait, assist, build, RallyPoint, RepeatBuild, patrol')
                end
            end
        end
    end,

    -- Waiting for previous command to be done
    SetFactoryWait = function(self, factory)
        local locked = true

        while locked do
            WaitSeconds(1)
        end
    end,

    -- Factory Rally Point
    SetFactoryRallyPoint = function(self ,factory, rallyPoint)
        IssueFactoryRallyPoint({factory}, ScenarioUtils.MarkerToPosition(rallyPoint))
    end,

    -- Factory Build
    SetFactoryBuildQueue = function(self, factory, tblQueue)
        for _, data in tblQueue do
            IssueBuildFactory({factory}, data[1], data[2])
        end
    end,

    -- Factory Assist
    SetFactoryAssist = function(self, factory, num)
        local type = self:GetFactoryType(factory)

        local targetFactory = nil
        while not targetFactory do
            targetFactory = self:GetFactory(type, num)
            WaitSeconds(1)
        end

        IssueFactoryAssist({factory}, targetFactory)
    end,

    -- Factory Patrol -- FIXME: Patrol nor attack move work on factories
    SetFactoryPatrol = function(self, factory, chain)
        for _, v in ScenarioUtils.ChainToPositions(chain) do
            IssuePatrol({factory}, v)
        end
    end,

    -- Repeat Build
    SetFactoryRepeatBuild = function(self, factory, val)
        local unitID = factory:GetEntityId()
        if not Sync.SetRepeatBuild then
            Sync.SetRepeatBuild = {}
        end

        Sync.SetRepeatBuild[unitID] = val
    end,

    ----------
    -- Attacks
    ----------
    SetAttackGroups = function(self, data)
        self.Units.AttackGroups = data

        -- Create table for storing actual units
        for num, group in self.Units.AttackGroups do
            if not group.AttackForce then
                group.AttackForce = {}
            end

            group.Number = num
        end
    end,

    GetAttackGroup = function(self, number)
        return self.Units.AttackGroups[number]
    end,

    -- Main thread for managing newly built units
    NewUnitsMonitor = function(self)
        while self.Active do
            local units = self.AIBrain:GetListOfUnits(categories.MOBILE - categories.ENGINEER, false, true)

            for _, unit in units do
                if not unit.Used and unit:GetFractionComplete() == 1 then
                    self:AssignUnitToAttackGroup(unit)

                    unit.Used = true
                end
            end
            WaitSeconds(4)
        end
    end,

    AssignUnitToAttackGroup = function(self, unit)
        for _, group in self.Units.AttackGroups do
            if not group.Formed then
                for _, data in group.units do
                    if data[2] > 0 and EntityCategoryContains(ParseEntityCategory(data[1]), unit) then
                        table.insert(group.AttackForce, unit)
                        data[2] = data[2] - 1

                        if self:CanFormAttackGroup(group) then
                            self:FormAttackGroup(group)
                        end
                        return
                    end
                end
            end
        end
    end,

    CanFormAttackGroup = function(self, group)
        for _, data in group.units do
            if data[2] > 0 then
                return false
            end
        end
        return true
    end,

    FormAttackGroup = function(self, group)
        group.Formed = true

        self:PlayeVoiceOver('AttackGroup' .. group.Number)

        self:ForkThread(self.AssignAttackGroupOrders, group)
    end,

    AssignAttackGroupOrders = function(self, group)
        local units = group.AttackForce

        self:IssueGroupStopClearCommands(units)

        for _, order in group.orders or {} do
            for action, data in order do
                if action == 'assist' then
                    self:IssueGroupAssist(units, data)
                elseif action == 'attackmove' then
                    self:IssueGroupAttackMove(units, data)
                elseif action == 'move' then
                    self:IssueGroupMove(units, data)
                elseif action == 'patrol' then
                    self:IssueGroupPatrol(units, data)
                else
                    WARN('*TUTORIAL MANAGER ERROR: AssignAttackGroupOrders, unknown action type: "' .. action .. '". Supported types: assist, attackmove, move, patrol')
                end
            end
        end
    end,

    ----------------
    -- Common Orders
    ----------------
    IssueGroupStopClearCommands = function(sefl, group)
        IssueStop(group)
        IssueClearCommands(group)
    end,

    IssueGroupAssist = function(self, group, data)
        if not type(data) == 'table' then
            error('*TUTORIAL MANAGER ERROR: IssueGroupAssist requires table as a second parametr. Provided type: ' .. type(data), 2)
        end

        local target = nil
        local targetType = data[1]
        local num = data[2]

        while not target do
            if targetType == 'ACU' then
                target = self.Units.ACU
            elseif targetType == 'Engineer' then
                target = self.Units.Engineers[num]
            elseif targetType == 'Factory' then
                target = self.Units.Factories[num]
            elseif targetType == 'AttackGroup' then
                -- First unit of the attack group
                target = self:GetAttackGroup(num).AttackForce[1]
            end
            
            WaitSeconds(3)
        end

        IssueGuard(group, target)
    end,

    IssueGroupAttackMove = function(self, group, data)
        if type(data) == 'string' then
            if string.find(data, 'Chain') then
                for _, v in ScenarioUtils.ChainToPositions(data) do
                    IssueAggressiveMove(group, v)
                end
            else
                IssueAggressiveMove(group, ScenarioUtils.MarkerToPosition(data))
            end
        elseif type(data) == 'table' then
            for _, marker in data do
                IssueAggressiveMove(group, ScenarioUtils.MarkerToPosition(marker))
            end
        end
    end,

    IssueGroupMove = function(self, group, data)
        if type(data) == 'string' then
            if string.find(data, 'Chain') then
                for _, v in ScenarioUtils.ChainToPositions(data) do
                    IssueMove(group, v)
                end
            else
                IssueMove(group, ScenarioUtils.MarkerToPosition(data))
            end
        elseif type(data) == 'table' then
            for _, marker in data do
                IssueMove(group, ScenarioUtils.MarkerToPosition(marker))
            end
        end
    end,

    IssueGroupPatrol = function(self, group, data)
        if type(data) == 'string' then
            for _, v in ScenarioUtils.ChainToPositions(data) do
                IssuePatrol(group, v)
            end
        elseif type(data) == 'table' then
            for _, marker in data do
                IssuePatrol(group, ScenarioUtils.MarkerToPosition(marker))
            end
        end
    end,
}

function CreateTutorialManager()
    local tManager = TutorialManager()
    tManager:Create()
    
    return tManager
end