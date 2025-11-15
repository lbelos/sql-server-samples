-- =============================================
-- Material Lot Traceability Procedures
-- =============================================
-- These procedures provide complete material lot traceability for sales orders
-- using recursive BOM explosion and FIFO lot allocation.
-- =============================================

-- Procedure 1: Get Material Lots for Sales Order with FIFO Allocation
-- =============================================
CREATE PROCEDURE usp_GetMaterialLotsForSalesOrder
    @SalesOrderRef VARCHAR(50) = NULL,
    @FutonSKU VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH SalesOrderItems AS (
        -- Get items from sales order
        SELECT
            m.SKU,
            m.Reference AS SalesOrder,
            m.TranDate AS SaleDate,
            ABS(m.Qty) AS QtySold
        FROM Movement m
        WHERE m.Type = 'SALE'
          AND (@SalesOrderRef IS NULL OR m.Reference = @SalesOrderRef)
          AND (@FutonSKU IS NULL OR m.SKU = @FutonSKU)
          AND m.Qty < 0
    ),

    -- Recursive BOM Explosion - Goes to all levels
    BOMExplosion AS (
        -- Anchor: Top level items (finished goods)
        SELECT
            s.SalesOrder,
            s.SKU AS TopLevelSKU,
            s.SKU AS CurrentSKU,
            s.QtySold AS TopLevelQty,
            CAST(s.QtySold AS DECIMAL(18,6)) AS ExtendedQty,
            0 AS BOMLevel,
            CAST(s.SKU AS VARCHAR(MAX)) AS BOMPath
        FROM SalesOrderItems s

        UNION ALL

        -- Recursive: Get components at each level
        SELECT
            be.SalesOrder,
            be.TopLevelSKU,
            b.Style AS CurrentSKU,
            be.TopLevelQty,
            CAST(be.ExtendedQty * ISNULL(b.Quantity, 1) AS DECIMAL(18,6)) AS ExtendedQty,
            be.BOMLevel + 1 AS BOMLevel,
            CAST(be.BOMPath + ' -> ' + b.Style AS VARCHAR(MAX)) AS BOMPath
        FROM BOMExplosion be
        INNER JOIN BOM b ON be.CurrentSKU = b.ID
        WHERE b.Style IS NOT NULL
          AND b.Style != b.ID  -- Avoid self-reference
          AND be.BOMLevel < 20  -- Safety limit to prevent infinite recursion
          AND be.BOMPath NOT LIKE '%' + b.Style + '%'  -- Prevent circular references
    ),

    -- Get only raw materials (leaf nodes - items that don't appear as parent in BOM)
    RawMaterials AS (
        SELECT DISTINCT
            be.SalesOrder,
            be.TopLevelSKU,
            be.CurrentSKU AS MaterialStyle,
            SUM(be.ExtendedQty) AS TotalMaterialQty,
            MAX(be.BOMLevel) AS MaxLevel,
            MAX(be.BOMPath) AS MaterialPath
        FROM BOMExplosion be
        WHERE NOT EXISTS (
            -- Check if this item has any components (is it a parent?)
            SELECT 1
            FROM BOM b
            WHERE b.ID = be.CurrentSKU
              AND b.Style IS NOT NULL
              AND b.Style != b.ID
        )
        GROUP BY
            be.SalesOrder,
            be.TopLevelSKU,
            be.CurrentSKU
    ),

    -- Get all receipts with lot numbers
    MaterialReceipts AS (
        SELECT
            m.Style,
            m.Serial_Lot,
            m.TranDate,
            m.Reference,
            m.Qty,
            m.UnitCost,
            m.ID,
            -- Running total for FIFO
            SUM(m.Qty) OVER (
                PARTITION BY m.Style
                ORDER BY
                    m.TranDate,
                    CASE WHEN m.Serial_Lot IS NOT NULL THEN 0 ELSE 1 END,
                    m.Reference,
                    m.ID
                ROWS UNBOUNDED PRECEDING
            ) AS RunningQtyReceived,
            ROW_NUMBER() OVER (
                PARTITION BY m.Style
                ORDER BY
                    m.TranDate,
                    CASE WHEN m.Serial_Lot IS NOT NULL THEN 0 ELSE 1 END,
                    m.Reference,
                    m.ID
            ) AS ReceiptSequence
        FROM Movement m
        WHERE m.Type IN ('RECV', 'PI', 'BI')  -- Only receipts
          AND m.Qty > 0
          AND m.Style IN (SELECT DISTINCT MaterialStyle FROM RawMaterials)
    ),

    -- Calculate consumed quantities up to each point in time
    MaterialConsumption AS (
        SELECT
            m.Style,
            m.TranDate,
            m.Reference,
            m.Type,
            ABS(m.Qty) AS QtyConsumed,
            m.ID,
            SUM(ABS(m.Qty)) OVER (
                PARTITION BY m.Style
                ORDER BY m.TranDate, m.Reference, m.ID
                ROWS UNBOUNDED PRECEDING
            ) AS RunningQtyConsumed
        FROM Movement m
        WHERE m.Type IN ('MFG', 'SALE', 'DIST', 'TRAN', 'ADJ')  -- Consumption transactions
          AND m.Qty < 0
          AND m.Style IN (SELECT DISTINCT MaterialStyle FROM RawMaterials)
    ),

    -- FIFO Lot Assignment with proper lot depletion handling
    FIFOAllocation AS (
        SELECT
            rm.SalesOrder,
            rm.TopLevelSKU,
            rm.MaterialStyle,
            rm.TotalMaterialQty,
            rm.MaxLevel,
            rm.MaterialPath,
            r.Serial_Lot,
            r.TranDate AS LotReceiptDate,
            r.Reference AS LotReference,
            r.UnitCost AS LotUnitCost,
            r.Qty AS LotTotalQty,
            r.RunningQtyReceived,
            r.ReceiptSequence,
            -- Calculate available quantity from this lot at time of consumption
            CASE
                -- Lot hasn't been touched yet
                WHEN NOT EXISTS (
                    SELECT 1 FROM MaterialConsumption c
                    WHERE c.Style = r.Style
                      AND c.TranDate <= r.TranDate
                )
                THEN r.Qty
                -- Calculate remaining in this lot after prior consumption
                ELSE r.Qty - ISNULL((
                    SELECT SUM(ABS(c.QtyConsumed))
                    FROM MaterialConsumption c
                    WHERE c.Style = r.Style
                      AND (
                          c.TranDate < r.TranDate
                          OR (c.TranDate = r.TranDate AND c.Reference <= r.Reference)
                      )
                      AND c.RunningQtyConsumed <= r.RunningQtyReceived
                      AND c.RunningQtyConsumed > (r.RunningQtyReceived - r.Qty)
                ), 0)
            END AS AvailableQtyInLot,
            -- Allocate from this lot using CASE instead of LEAST
            CASE
                WHEN r.RunningQtyReceived <= rm.TotalMaterialQty
                     AND (r.RunningQtyReceived - r.Qty) < rm.TotalMaterialQty
                THEN
                    -- Get minimum of three values using nested CASE
                    CASE
                        WHEN r.Qty < rm.TotalMaterialQty - (r.RunningQtyReceived - r.Qty)
                        THEN
                            CASE
                                WHEN r.Qty < r.Qty - ISNULL((
                                    SELECT SUM(ABS(c.QtyConsumed))
                                    FROM MaterialConsumption c
                                    WHERE c.Style = r.Style
                                      AND c.RunningQtyConsumed <= r.RunningQtyReceived
                                      AND c.RunningQtyConsumed > (r.RunningQtyReceived - r.Qty)
                                ), 0)
                                THEN r.Qty
                                ELSE r.Qty - ISNULL((
                                    SELECT SUM(ABS(c.QtyConsumed))
                                    FROM MaterialConsumption c
                                    WHERE c.Style = r.Style
                                      AND c.RunningQtyConsumed <= r.RunningQtyReceived
                                      AND c.RunningQtyConsumed > (r.RunningQtyReceived - r.Qty)
                                ), 0)
                            END
                        ELSE
                            CASE
                                WHEN rm.TotalMaterialQty - (r.RunningQtyReceived - r.Qty) < r.Qty - ISNULL((
                                    SELECT SUM(ABS(c.QtyConsumed))
                                    FROM MaterialConsumption c
                                    WHERE c.Style = r.Style
                                      AND c.RunningQtyConsumed <= r.RunningQtyReceived
                                      AND c.RunningQtyConsumed > (r.RunningQtyReceived - r.Qty)
                                ), 0)
                                THEN rm.TotalMaterialQty - (r.RunningQtyReceived - r.Qty)
                                ELSE r.Qty - ISNULL((
                                    SELECT SUM(ABS(c.QtyConsumed))
                                    FROM MaterialConsumption c
                                    WHERE c.Style = r.Style
                                      AND c.RunningQtyConsumed <= r.RunningQtyReceived
                                      AND c.RunningQtyConsumed > (r.RunningQtyReceived - r.Qty)
                                ), 0)
                            END
                    END
                ELSE 0
            END AS AllocatedQty
        FROM RawMaterials rm
        CROSS APPLY (
            SELECT *
            FROM MaterialReceipts mr
            WHERE mr.Style = rm.MaterialStyle
              AND mr.RunningQtyReceived > 0
        ) r
        WHERE r.Qty > 0
    )

    -- Final Result with Complete Traceability
    SELECT
        f.SalesOrder,
        f.TopLevelSKU AS FutonSKU,
        f.MaterialStyle,
        f.MaxLevel AS BOMDepth,
        f.MaterialPath AS ComponentPath,
        f.TotalMaterialQty AS TotalQtyNeeded,
        f.Serial_Lot,
        f.LotReceiptDate,
        f.LotReference,
        f.LotUnitCost,
        f.LotTotalQty,
        SUM(f.AllocatedQty) AS QtyAllocatedFromLot,
        -- Calculate if there are any shortages
        f.TotalMaterialQty - SUM(SUM(f.AllocatedQty)) OVER (
            PARTITION BY f.SalesOrder, f.TopLevelSKU, f.MaterialStyle
        ) AS RemainingShortage
    FROM FIFOAllocation f
    WHERE f.AllocatedQty > 0
    GROUP BY
        f.SalesOrder,
        f.TopLevelSKU,
        f.MaterialStyle,
        f.MaxLevel,
        f.MaterialPath,
        f.TotalMaterialQty,
        f.Serial_Lot,
        f.LotReceiptDate,
        f.LotReference,
        f.LotUnitCost,
        f.LotTotalQty
    ORDER BY
        f.SalesOrder,
        f.TopLevelSKU,
        f.MaterialStyle,
        f.LotReceiptDate,
        f.ReceiptSequence;
END;
GO

-- =============================================
-- Procedure 2: Simplified version for single SKU lookup
-- =============================================
CREATE PROCEDURE usp_GetMaterialLotsForSKU
    @SKU VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    WITH BOMExplosion AS (
        -- Anchor: Top level
        SELECT
            @SKU AS TopLevelSKU,
            @SKU AS CurrentSKU,
            CAST(1.0 AS DECIMAL(18,6)) AS Quantity,
            0 AS Level,
            CAST(@SKU AS VARCHAR(1000)) AS Path

        UNION ALL

        -- Recursive: Explode components
        SELECT
            be.TopLevelSKU,
            b.Style AS CurrentSKU,
            CAST(be.Quantity * ISNULL(b.Quantity, 1) AS DECIMAL(18,6)) AS Quantity,
            be.Level + 1 AS Level,
            CAST(be.Path + ' -> ' + b.Style AS VARCHAR(1000)) AS Path
        FROM BOMExplosion be
        INNER JOIN BOM b ON be.CurrentSKU = b.ID
        WHERE b.Style IS NOT NULL
          AND b.Style != b.ID
          AND be.Level < 20
          AND CHARINDEX(b.Style, be.Path) = 0  -- Prevent circular references
    ),

    -- Get raw materials (leaf nodes)
    RawMaterials AS (
        SELECT
            be.TopLevelSKU,
            be.CurrentSKU AS MaterialStyle,
            SUM(be.Quantity) AS TotalQty,
            MAX(be.Level) AS MaxLevel,
            MAX(be.Path) AS Path
        FROM BOMExplosion be
        WHERE NOT EXISTS (
            SELECT 1 FROM BOM b
            WHERE b.ID = be.CurrentSKU
              AND b.Style IS NOT NULL
              AND b.Style != b.ID
        )
        GROUP BY be.TopLevelSKU, be.CurrentSKU
    )

    -- Get receipts with lots
    SELECT
        rm.TopLevelSKU AS FutonSKU,
        rm.MaterialStyle,
        rm.MaxLevel AS BOMDepth,
        rm.Path AS ComponentPath,
        rm.TotalQty AS QuantityPerUnit,
        m.Serial_Lot,
        m.TranDate AS ReceiptDate,
        m.Reference AS ReceiptReference,
        m.Qty AS ReceiptQty,
        m.UnitCost
    FROM RawMaterials rm
    INNER JOIN Movement m ON rm.MaterialStyle = m.Style
    WHERE m.Type IN ('RECV', 'PI', 'BI')
      AND m.Qty > 0
      AND m.Serial_Lot IS NOT NULL
    ORDER BY
        rm.MaterialStyle,
        m.TranDate,
        m.Reference;
END;
GO
