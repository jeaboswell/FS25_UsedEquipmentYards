EquipmentPurchasedEvent = {}
local EquipmentPurchasedEvent_mt = Class(EquipmentPurchasedEvent, Event)

InitEventClass(EquipmentPurchasedEvent, "EquipmentPurchasedEvent")

local function reply(connection, self, reason, price, creditUsed)
    connection:sendEvent(PurchaseResultEvent.new(self.yardId, self.vehicleObjectId, self.farmId, reason, price or 0, creditUsed or 0))
end

function EquipmentPurchasedEvent.emptyNew()
    return Event.new(EquipmentPurchasedEvent_mt)
end

function EquipmentPurchasedEvent.new(yardId, itemIndex, farmId, creditUsed, vehicleUniqueId, purchasePrice, vehicleObjectId)
    local self = EquipmentPurchasedEvent.emptyNew()
    self.yardId          = yardId
    self.itemIndex       = itemIndex
    self.farmId          = farmId
    self.creditUsed      = creditUsed or 0
    self.vehicleUniqueId = vehicleUniqueId or ""
    self.purchasePrice   = purchasePrice or 0
    self.vehicleObjectId = vehicleObjectId or 0
    return self
end

function EquipmentPurchasedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.itemIndex)
    streamWriteInt32(streamId, self.vehicleObjectId)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.creditUsed)
    streamWriteString(streamId, self.vehicleUniqueId)
    streamWriteInt32(streamId, self.purchasePrice)
end

function EquipmentPurchasedEvent:readStream(streamId, connection)
    self.yardId          = streamReadInt32(streamId)
    self.itemIndex       = streamReadInt32(streamId)
    self.vehicleObjectId = streamReadInt32(streamId)
    self.farmId          = streamReadInt32(streamId)
    self.creditUsed      = streamReadInt32(streamId)
    self.vehicleUniqueId = streamReadString(streamId)
    self.purchasePrice   = streamReadInt32(streamId)
    self:run(connection)
end

function EquipmentPurchasedEvent:run(connection)
    if not connection:getIsServer() then
        -- -----------------------------------------------------------------
        -- SERVER: received from client — validate, deduct, transfer, broadcast.
        -- -----------------------------------------------------------------
        local manager = UsedEquipmentYards.yardManager
        if manager == nil then
            Logging.warning("[UsedEquipmentYards] purchase request but yardManager is nil")
            return
        end

        local yard = manager.yards[self.yardId]
        if yard == nil then
            Logging.warning("[UsedEquipmentYards] purchase request for unknown yard id %d — ignored", self.yardId)
            reply(connection, self, PurchaseResultEvent.REASON_NO_YARD)
            return
        end

        -- Resolve by vehicle network object id — itemIndex drifts between
        -- server and clients when earlier items are removed. No index fallback:
        -- a rejected purchase is better than charging for the wrong item.
        local item, itemIndex = UsedEquipmentYards.resolveServerItem(yard, self.vehicleObjectId)
        if item == nil then
            Logging.warning("[UsedEquipmentYards] purchase/test-drive request for unknown yard vehicle (objectId %s) — ignored", tostring(self.vehicleObjectId))
            local v = NetworkUtil.getObject(self.vehicleObjectId)
            if v == nil then
                Logging.warning("[UsedEquipmentYards]   objectId %s does not resolve to any network object", tostring(self.vehicleObjectId))
            else
                Logging.warning("[UsedEquipmentYards]   resolves to '%s' uniqueId=%s ownerFarmId=%s; yard %d has %d inventory items",
                    v.getFullName and v:getFullName() or "?",
                    tostring(v.uniqueId),
                    tostring(v.ownerFarmId),
                    self.yardId,
                    #yard.inventory.items)
                for otherYardId, otherYard in pairs(manager.yards) do
                    if otherYardId ~= self.yardId and otherYard.inventory ~= nil then
                        for _, otherItem in pairs(otherYard.inventory.items) do
                            if otherItem.vehicle == v then
                                Logging.warning("[UsedEquipmentYards]   vehicle found in yard %d instead", otherYardId)
                                break
                            end
                        end
                    end
                end
                if UsedEquipmentYards.vehicleToItem ~= nil and UsedEquipmentYards.vehicleToItem[v] ~= nil then
                    Logging.warning("[UsedEquipmentYards]   vehicle is still tracked in vehicleToItem")
                end
            end
            reply(connection, self, PurchaseResultEvent.REASON_UNKNOWN_ITEM)
            return
        end

        -- Honour an accepted barter offer sent as purchasePrice; the server
        -- re-validates it against the item's minimum price.
        local price = item.price
        if self.purchasePrice ~= nil and self.purchasePrice > 0 then
            local minPrice = item.minPrice or item.price
            if self.purchasePrice < minPrice then
                Logging.warning("[UsedEquipmentYards] rejected barter offer %d below minimum %d for yard item", self.purchasePrice, minPrice)
                reply(connection, self, PurchaseResultEvent.REASON_BELOW_MIN)
                return
            end
            price = math.min(self.purchasePrice, item.price)
        end

        local farm = g_farmManager:getFarmById(self.farmId)
        local creditAvailable = YardCredit.getBalance(self.farmId, self.yardId)
        if farm == nil or (farm:getBalance() + creditAvailable) < price then
            Logging.warning("[UsedEquipmentYards] purchase rejected: farm %d balance %d + credit %d < price %d",
                self.farmId, farm ~= nil and math.floor(farm:getBalance()) or -1, math.floor(creditAvailable), math.floor(price))
            reply(connection, self, PurchaseResultEvent.REASON_INSUFFICIENT_FUNDS)
            return
        end

        -- Deduct credit first, remainder from cash.
        local creditUsed = YardCredit.deductCredit(self.farmId, self.yardId, price)
        local cashCost = price - creditUsed
        if cashCost > 0 then
            g_currentMission:addMoneyChange(-cashCost, self.farmId, MoneyType.SHOP_VEHICLE_BUY, true)
            g_farmManager:getFarmById(self.farmId):changeBalance(-cashCost, MoneyType.SHOP_VEHICLE_BUY)
        end

        local vehicle = item.vehicle
        local vehicleUniqueId = (vehicle ~= nil) and vehicle.uniqueId or ""
        local purchasePrice = price

        if vehicle ~= nil then
            YardInventory.detachVehicle(vehicle)

            vehicle:setOwnerFarmId(self.farmId)
            PriceTagRenderer.removeTag(vehicle)
            UsedEquipmentYards.restoreLicensePlate(vehicle)
            UsedEquipmentYards.clearVehicleRestrictions(vehicle)
        end

        -- Record this sale so resale offers are capped below purchase price.
        UsedEquipmentYards.addRecentSale(vehicleUniqueId, purchasePrice)

        -- Capture label before removeItem clears item.vehicle.
        local label = UsedEquipmentYards.itemLabel(item, vehicle)

        -- Remove from inventory tracking; keepVehicle=true — vehicle stays.
        yard.inventory:removeItem(item, true)

        Logging.info("[UsedEquipmentYards] purchase: farm %d bought %s from yard %d '%s' for %d (asking %d, credit used %d, cash %d)",
            self.farmId, label, yard.id, yard.name, math.floor(price), math.floor(item.price), math.floor(creditUsed), math.floor(cashCost))

        -- Broadcast so remote multiplayer clients also clean up their state.
        g_server:broadcastEvent(EquipmentPurchasedEvent.new(self.yardId, itemIndex, self.farmId, creditUsed, vehicleUniqueId, purchasePrice, self.vehicleObjectId))
        reply(connection, self, PurchaseResultEvent.REASON_OK, price, creditUsed)
        return
    end

    -- -----------------------------------------------------------------
    -- CLIENT: remote client receiving the broadcast — clean up local state.
    -- -----------------------------------------------------------------

    -- Listen server host: clean up via yardManager.
    local manager = UsedEquipmentYards.yardManager
    if manager ~= nil then
        local yard = manager.yards[self.yardId]
        if yard ~= nil then
            local item = nil
            if self.vehicleObjectId ~= nil and self.vehicleObjectId ~= 0 then
                item = UsedEquipmentYards.resolveServerItem(yard, self.vehicleObjectId)
            else
                item = yard.inventory.items[self.itemIndex]
            end
            if item ~= nil then
                local vehicle = item.vehicle
                if vehicle ~= nil then
                    vehicle:setOwnerFarmId(self.farmId)
                    PriceTagRenderer.removeTag(vehicle)
                    UsedEquipmentYards.restoreLicensePlate(vehicle)
                    UsedEquipmentYards.clearVehicleRestrictions(vehicle)
                end
                yard.inventory:removeItem(item, true)
            end
        end
    end

    -- Remote client: assign ownership via clientItems before cleanup removes the reference.
    local clientItem = nil
    if self.vehicleObjectId ~= nil and self.vehicleObjectId ~= 0 then
        clientItem = UsedEquipmentYards.resolveClientItem(self.yardId, self.vehicleObjectId)
    end
    if clientItem ~= nil and clientItem.vehicle ~= nil then
        clientItem.vehicle:setOwnerFarmId(self.farmId)
    end

    -- Sync balance and credit deduction on this client.
    local cashCost = self.purchasePrice - (self.creditUsed or 0)
    if cashCost > 0 then
        g_farmManager:getFarmById(self.farmId):changeBalance(-cashCost, MoneyType.SHOP_VEHICLE_BUY)
    end
    if self.creditUsed > 0 then
        YardCredit.deductCredit(self.farmId, self.yardId, self.creditUsed)
    end

    -- Record this sale so resale offers are capped below purchase price.
    if self.vehicleUniqueId ~= "" and self.purchasePrice > 0 then
        UsedEquipmentYards.addRecentSale(self.vehicleUniqueId, self.purchasePrice)
    end

    -- Clean up client-side item registry (remote MP clients).
    UsedEquipmentYards.removeClientItem(self.yardId, self.itemIndex, self.vehicleObjectId)
end

