-- =============================================
-- Material Lot Consumption Tracking (FIFO)
-- =============================================
-- This procedure tracks which material lots were consumed for each sale
-- using FIFO logic to show complete lot traceability
-- =============================================

CREATE PROCEDURE usp_GetMaterialLotConsumptionFIFO
    @FutonSKU VARCHAR(50),
    @OrderID VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Get all sales for this SKU
    WITH Sales AS (
        SELECT
            m.ID AS SaleID,
            m.Reference AS OrderID,
            m.TranDate AS OrderDate,
            m.SKU,
            ABS(m.Qty) AS QtySold,
            -- Running total of sales for FIFO processing
            SUM(ABS(m.Qty)) OVER (
                PARTITION BY m.SKU
                ORDER BY m.TranDate, m.Reference, m.ID
                ROWS UNBOUNDED PRECEDING
            ) AS CumulativeQtySold,
            ROW_NUMBER() OVER (
                PARTITION BY m.SKU
                ORDER BY m.TranDate, m.Reference, m.ID
            ) AS SaleSequence
        FROM Movement m
        WHERE m.Type = 'SALE'
          AND m.SKU = @FutonSKU
          AND (@OrderID IS NULL OR m.Reference = @OrderID)
          AND m.Qty < 0
    ),

    -- Recursive BOM Explosion to get raw materials
    BOMExplosion AS (
        -- Anchor: Top level (the futon)
        SELECT
            CAST(@FutonSKU AS VARCHAR(100)) AS TopLevelSKU,
            CAST(@FutonSKU AS VARCHAR(100)) AS CurrentSKU,
            CAST(1.0 AS DECIMAL(18,6)) AS QtyPerUnit,
            0 AS BOMLevel,
            CAST(@FutonSKU AS VARCHAR(1000)) AS BOMPath

        UNION ALL

        -- Recursive: Get components
        SELECT
            CAST(be.TopLevelSKU AS VARCHAR(100)) AS TopLevelSKU,
            CAST(b.Style AS VARCHAR(100)) AS CurrentSKU,
            CAST(be.QtyPerUnit * ISNULL(b.Quantity, 1) AS DECIMAL(18,6)) AS QtyPerUnit,
            be.BOMLevel + 1 AS BOMLevel,
            CAST(be.BOMPath + ' -> ' + b.Style AS VARCHAR(1000)) AS BOMPath
        FROM BOMExplosion be
        INNER JOIN BOM b ON be.CurrentSKU = b.ID
        WHERE b.Style IS NOT NULL
          AND b.Style != b.ID
          AND be.BOMLevel < 20
          AND CHARINDEX(b.Style, be.BOMPath) = 0
    ),

    -- Get only raw materials (leaf nodes)
    RawMaterials AS (
        SELECT
            be.TopLevelSKU,
            be.CurrentSKU AS MaterialStyle,
            be.QtyPerUnit AS QtyPerFuton,
            be.BOMLevel,
            be.BOMPath
        FROM BOMExplosion be
        WHERE NOT EXISTS (
            SELECT 1
            FROM BOM b
            WHERE b.ID = be.CurrentSKU
              AND b.Style IS NOT NULL
              AND b.Style != b.ID
        )
    ),

    -- Get all material receipts (lots) in FIFO order
    MaterialReceipts AS (
        SELECT
            m.Style,
            m.Serial_Lot,
            m.TranDate AS ReceiptDate,
            m.Reference AS ReceiptRef,
            m.Qty AS LotQty,
            m.UnitCost,
            m.ID,
            -- Running total of receipts for FIFO
            SUM(m.Qty) OVER (
                PARTITION BY m.Style
                ORDER BY m.TranDate, m.Reference, m.ID
                ROWS UNBOUNDED PRECEDING
            ) AS CumulativeReceipts,
            SUM(m.Qty) OVER (
                PARTITION BY m.Style
                ORDER BY m.TranDate, m.Reference, m.ID
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS PriorCumulativeReceipts,
            ROW_NUMBER() OVER (
                PARTITION BY m.Style
                ORDER BY m.TranDate, m.Reference, m.ID
            ) AS ReceiptSequence
        FROM Movement m
        WHERE m.Type IN ('RECV', 'PI', 'BI')
          AND m.Qty > 0
          AND m.Style IN (SELECT DISTINCT MaterialStyle FROM RawMaterials)
    ),

    -- Calculate material requirements for each sale
    SaleMaterialRequirements AS (
        SELECT
            s.SaleID,
            s.OrderID,
            s.OrderDate,
            s.SKU,
            s.QtySold,
            s.CumulativeQtySold,
            s.SaleSequence,
            rm.MaterialStyle,
            rm.QtyPerFuton,
            rm.BOMLevel,
            rm.BOMPath,
            -- Total material needed for this sale
            s.QtySold * rm.QtyPerFuton AS MaterialQtyNeeded,
            -- Cumulative material consumed up to and including this sale
            s.CumulativeQtySold * rm.QtyPerFuton AS CumulativeMaterialConsumed,
            -- Cumulative material consumed before this sale
            (s.CumulativeQtySold - s.QtySold) * rm.QtyPerFuton AS PriorMaterialConsumed
        FROM Sales s
        CROSS JOIN RawMaterials rm
    ),

    -- FIFO Lot Allocation: Match receipts to sales
    LotAllocation AS (
        SELECT
            smr.SaleID,
            smr.OrderID,
            smr.OrderDate,
            smr.SKU AS FutonSKU,
            smr.QtySold,
            smr.SaleSequence,
            smr.MaterialStyle,
            smr.QtyPerFuton,
            smr.BOMLevel,
            smr.BOMPath,
            smr.MaterialQtyNeeded,
            mr.Serial_Lot,
            mr.ReceiptDate,
            mr.ReceiptRef,
            mr.LotQty,
            mr.UnitCost,
            mr.ReceiptSequence,
            mr.CumulativeReceipts,
            mr.PriorCumulativeReceipts,
            -- Calculate how much from this lot is allocated to this sale
            CASE
                -- Lot is completely before this sale's consumption range
                WHEN mr.CumulativeReceipts <= smr.PriorMaterialConsumed THEN 0
                -- Lot is completely after this sale's consumption range
                WHEN ISNULL(mr.PriorCumulativeReceipts, 0) >= smr.CumulativeMaterialConsumed THEN 0
                -- Lot is partially consumed by this sale
                ELSE
                    CASE
                        -- Available from lot start
                        WHEN ISNULL(mr.PriorCumulativeReceipts, 0) >= smr.PriorMaterialConsumed
                        THEN
                            -- MIN(lot available, material still needed)
                            CASE
                                WHEN mr.CumulativeReceipts - ISNULL(mr.PriorCumulativeReceipts, 0)
                                     < smr.CumulativeMaterialConsumed - ISNULL(mr.PriorCumulativeReceipts, 0)
                                THEN mr.CumulativeReceipts - ISNULL(mr.PriorCumulativeReceipts, 0)
                                ELSE smr.CumulativeMaterialConsumed - ISNULL(mr.PriorCumulativeReceipts, 0)
                            END
                        -- Lot started being consumed before this sale
                        ELSE
                            -- MIN(remaining in lot, material needed for this sale)
                            CASE
                                WHEN mr.CumulativeReceipts - smr.PriorMaterialConsumed < smr.MaterialQtyNeeded
                                THEN mr.CumulativeReceipts - smr.PriorMaterialConsumed
                                ELSE smr.MaterialQtyNeeded
                            END
                    END
            END AS QtyConsumedFromLot
        FROM SaleMaterialRequirements smr
        CROSS JOIN MaterialReceipts mr
        WHERE mr.Style = smr.MaterialStyle
          AND mr.CumulativeReceipts > smr.PriorMaterialConsumed
          AND ISNULL(mr.PriorCumulativeReceipts, 0) < smr.CumulativeMaterialConsumed
    )

    -- Final Output: Show lot consumption for each sale
    SELECT
        la.OrderID,
        la.OrderDate,
        la.FutonSKU,
        la.QtySold AS FutonQtySold,
        la.SaleSequence,
        la.MaterialStyle,
        la.BOMLevel AS BOMDepth,
        la.BOMPath AS ComponentPath,
        la.QtyPerFuton AS MaterialQtyPerFuton,
        la.MaterialQtyNeeded AS TotalMaterialNeeded,
        la.Serial_Lot AS LotNumber,
        la.ReceiptDate AS LotReceiptDate,
        la.ReceiptRef AS LotReceiptRef,
        la.LotQty AS LotTotalQty,
        la.UnitCost AS LotUnitCost,
        la.ReceiptSequence AS LotFIFOSequence,
        la.QtyConsumedFromLot,
        -- Calculate cost allocation
        la.QtyConsumedFromLot * la.UnitCost AS CostFromThisLot,
        -- Show cumulative consumption from this lot
        SUM(la.QtyConsumedFromLot) OVER (
            PARTITION BY la.OrderID, la.MaterialStyle
            ORDER BY la.ReceiptSequence
        ) AS CumulativeQtyConsumed
    FROM LotAllocation la
    WHERE la.QtyConsumedFromLot > 0
    ORDER BY
        la.OrderDate,
        la.OrderID,
        la.SaleSequence,
        la.MaterialStyle,
        la.ReceiptSequence;
END;
GO
