-- PurchaseResultEvent
-- Server → Client: result of an EquipmentPurchasedEvent request so the
-- originating client only shows the "Purchased" popup after the server
-- has confirmed the sale, or shows the rejection reason otherwise.

PurchaseResultEvent = {}
local PurchaseResultEvent_mt = Class(PurchaseResultEvent, Event)

InitEventClass(PurchaseResultEvent, "PurchaseResultEvent")

PurchaseResultEvent.REASON_OK                 = 0
PurchaseResultEvent.REASON_NO_YARD            = 1
PurchaseResultEvent.REASON_UNKNOWN_ITEM       = 2
PurchaseResultEvent.REASON_BELOW_MIN          = 3
PurchaseResultEvent.REASON_INSUFFICIENT_FUNDS = 4

PurchaseResultEvent.REASON_TEXTS = {
    [PurchaseResultEvent.REASON_NO_YARD]            = "uey_purchase_failed_noYard",
    [PurchaseResultEvent.REASON_UNKNOWN_ITEM]       = "uey_purchase_failed_unknownItem",
    [PurchaseResultEvent.REASON_BELOW_MIN]          = "uey_purchase_failed_belowMin",
    [PurchaseResultEvent.REASON_INSUFFICIENT_FUNDS] = "uey_purchase_failed_funds",
}

function PurchaseResultEvent.emptyNew()
    return Event.new(PurchaseResultEvent_mt)
end

function PurchaseResultEvent.new(yardId, vehicleObjectId, farmId, reason, price, creditUsed)
    local self = PurchaseResultEvent.emptyNew()
    self.yardId          = yardId or 0
    self.vehicleObjectId = vehicleObjectId or 0
    self.farmId          = farmId or 0
    self.reason          = reason or 0
    self.price           = price or 0
    self.creditUsed      = creditUsed or 0
    return self
end

function PurchaseResultEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.vehicleObjectId)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.reason)
    streamWriteInt32(streamId, self.price)
    streamWriteInt32(streamId, self.creditUsed)
end

function PurchaseResultEvent:readStream(streamId, connection)
    self.yardId          = streamReadInt32(streamId)
    self.vehicleObjectId = streamReadInt32(streamId)
    self.farmId          = streamReadInt32(streamId)
    self.reason          = streamReadInt32(streamId)
    self.price           = streamReadInt32(streamId)
    self.creditUsed      = streamReadInt32(streamId)
    self:run(connection)
end

function PurchaseResultEvent:run(connection)
    -- CLIENT only: sent by the server to the requesting client.
    local farmId = g_currentMission:getFarmId()
    if farmId ~= self.farmId then return end

    if self.reason == PurchaseResultEvent.REASON_OK then
        local vehicle = NetworkUtil.getObject(self.vehicleObjectId)
        local name = vehicle ~= nil and vehicle:getFullName() or "?"
        InfoDialog.show(string.format(g_i18n:getText("uey_barter_purchased"), name, g_i18n:formatMoney(self.price)))
    else
        local key = PurchaseResultEvent.REASON_TEXTS[self.reason] or "uey_purchase_failed_generic"
        InfoDialog.show(g_i18n:getText(key))
    end
end
