-- ---------------------------------------------------------------------
-- 9. LISTAS DE PRECIOS Y DESCUENTOS
-- ---------------------------------------------------------------------
CREATE TABLE price_list (
    price_list_id   SERIAL PRIMARY KEY,
    name            VARCHAR(80) NOT NULL UNIQUE,
    base_list_id    INT REFERENCES price_list(price_list_id),  -- lista de la que deriva
    factor          NUMERIC(12,6) NOT NULL DEFAULT 1 CHECK (factor > 0),
    CHECK (base_list_id IS NULL OR base_list_id <> price_list_id)
);
ALTER TABLE sales_order
    ADD CONSTRAINT fk_so_price_list FOREIGN KEY (price_list_id) REFERENCES price_list(price_list_id);

CREATE TABLE item_price (
    price_list_id INT NOT NULL REFERENCES price_list(price_list_id),
    item_code     VARCHAR(50) NOT NULL REFERENCES item(item_code),
    price         NUMERIC(19,6) NOT NULL CHECK (price >= 0),
    PRIMARY KEY (price_list_id, item_code)
);

CREATE TABLE discount_group (
    discount_group_id SERIAL PRIMARY KEY,
    name              VARCHAR(80) NOT NULL UNIQUE,
    discount_pct      NUMERIC(7,4) NOT NULL CHECK (discount_pct BETWEEN 0 AND 100)
);
CREATE TABLE discount_group_item (
    discount_group_id INT NOT NULL REFERENCES discount_group(discount_group_id),
    item_code         VARCHAR(50) NOT NULL REFERENCES item(item_code),
    PRIMARY KEY (discount_group_id, item_code)
);
CREATE TABLE discount_group_partner (
    discount_group_id INT NOT NULL REFERENCES discount_group(discount_group_id),
    partner_code      VARCHAR(30) NOT NULL REFERENCES business_partner(partner_code),
    PRIMARY KEY (discount_group_id, partner_code)
);

-- =====================================================================
-- REGLAS DE NEGOCIO E INTEGRIDAD (triggers y funciones)
-- =====================================================================

-- ---------------------------------------------------------------------
-- RN01: Función ATP = stock físico + pedido en OC - comprometido en PV
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION calcular_atp(p_item_code VARCHAR)
RETURNS NUMERIC(19,6)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(on_hand), 0) + COALESCE(SUM(on_order), 0) - COALESCE(SUM(committed), 0)
    FROM item_stock
    WHERE item_code = p_item_code;
$$;

-- Vista: ATP calculado directamente desde los documentos abiertos (sin contadores)
CREATE OR REPLACE VIEW v_atp AS
SELECT i.item_code,
       COALESCE(s.on_hand, 0)                                  AS stock_fisico,
       COALESCE(po.pedido, 0)                                  AS pedido_oc,
       COALESCE(so.comprometido, 0)                            AS comprometido_pv,
       COALESCE(s.on_hand, 0) + COALESCE(po.pedido, 0) - COALESCE(so.comprometido, 0) AS atp
FROM item i
LEFT JOIN (SELECT item_code, SUM(on_hand) AS on_hand FROM item_stock GROUP BY item_code) s
       ON s.item_code = i.item_code
LEFT JOIN (SELECT l.item_code, SUM(l.qty_pending) AS pedido
           FROM purchase_order_line l JOIN purchase_order h USING (po_id)
           WHERE h.status = 'ABIERTA' GROUP BY l.item_code) po
       ON po.item_code = i.item_code
LEFT JOIN (SELECT l.item_code, SUM(l.qty_pending) AS comprometido
           FROM sales_order_line l JOIN sales_order h USING (so_id)
           WHERE h.status = 'ABIERTA' GROUP BY l.item_code) so
       ON so.item_code = i.item_code
WHERE i.is_inventory_item;

-- ---------------------------------------------------------------------
-- RN02: Trazabilidad obligatoria en cada línea de movimiento
-- (El backend debe mapear estos errores a HTTP 400:
--  P0001 'InvalidBatchNumber' / 'SerialRequired')
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_check_inventory_item() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_item item%ROWTYPE;
BEGIN
    SELECT * INTO v_item FROM item WHERE item_code = NEW.item_code;

    IF NOT v_item.is_inventory_item THEN
        RAISE EXCEPTION 'ItemNotInventory: el artículo % no es de inventario', NEW.item_code
              USING ERRCODE = 'P0001';
    END IF;

    IF v_item.batch_managed THEN
        IF NEW.batch_id IS NULL THEN
            RAISE EXCEPTION 'InvalidBatchNumber: lote requerido para el artículo %', NEW.item_code
                  USING ERRCODE = 'P0001';
        END IF;
        -- el lote debe pertenecer al mismo artículo
        IF NOT EXISTS (SELECT 1 FROM batch b
                       WHERE b.batch_id = NEW.batch_id AND b.item_code = NEW.item_code) THEN
            RAISE EXCEPTION 'InvalidBatchNumber: el lote no corresponde al artículo %', NEW.item_code
                  USING ERRCODE = 'P0001';
        END IF;
    ELSIF NEW.batch_id IS NOT NULL THEN
        RAISE EXCEPTION 'InvalidBatchNumber: el artículo % no se gestiona por lotes', NEW.item_code
              USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_idl_check_item
    BEFORE INSERT ON inventory_doc_line
    FOR EACH ROW EXECUTE FUNCTION trg_check_inventory_item();

-- Series: al confirmar la transacción, nº de series = |qty_base| (DEFERRED)
CREATE OR REPLACE FUNCTION trg_check_serials() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_serial BOOLEAN; v_count INT;
BEGIN
    SELECT serial_managed INTO v_serial FROM item WHERE item_code = NEW.item_code;
    IF v_serial THEN
        SELECT COUNT(*) INTO v_count FROM inventory_doc_line_serial WHERE line_id = NEW.line_id;
        IF v_count <> abs(NEW.qty_base) THEN
            RAISE EXCEPTION 'SerialRequired: Asignación de serie requerida (artículo %, esperadas %, recibidas %)',
                  NEW.item_code, abs(NEW.qty_base), v_count USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_idl_check_serials
    AFTER INSERT ON inventory_doc_line
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_serials();

-- ---------------------------------------------------------------------
-- RN03: Inmutabilidad. Solo se permite pasar un documento de
-- PUBLICADO a CANCELADO (lo hace el documento de reversión).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_block_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'ImmutableDocument: los documentos de inventario no pueden editarse ni eliminarse; use una reversión'
          USING ERRCODE = 'P0001';
END $$;

CREATE TRIGGER trg_idl_immutable
    BEFORE UPDATE OR DELETE ON inventory_doc_line
    FOR EACH ROW EXECUTE FUNCTION trg_block_modification();

CREATE TRIGGER trg_idls_immutable
    BEFORE UPDATE OR DELETE ON inventory_doc_line_serial
    FOR EACH ROW EXECUTE FUNCTION trg_block_modification();

CREATE TRIGGER trg_idoc_no_delete
    BEFORE DELETE ON inventory_doc
    FOR EACH ROW EXECUTE FUNCTION trg_block_modification();

CREATE OR REPLACE FUNCTION trg_doc_only_cancel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'PUBLICADO' AND NEW.status = 'CANCELADO'
       AND (OLD.doc_id, OLD.doc_type, OLD.doc_date, OLD.je_id, OLD.created_at)
           IS NOT DISTINCT FROM (NEW.doc_id, NEW.doc_type, NEW.doc_date, NEW.je_id, NEW.created_at)
       AND EXISTS (SELECT 1 FROM inventory_doc r
                   WHERE r.reversal_of_doc_id = OLD.doc_id AND r.doc_type = 'REVERSION') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'ImmutableDocument: solo se permite cancelar mediante un documento de reversión'
          USING ERRCODE = 'P0001';
END $$;

CREATE TRIGGER trg_idoc_only_cancel
    BEFORE UPDATE ON inventory_doc
    FOR EACH ROW EXECUTE FUNCTION trg_doc_only_cancel();

-- Los asientos contables también son inmutables
CREATE TRIGGER trg_je_immutable
    BEFORE UPDATE OR DELETE ON journal_entry
    FOR EACH ROW EXECUTE FUNCTION trg_block_modification();
CREATE TRIGGER trg_jel_immutable
    BEFORE UPDATE OR DELETE ON journal_entry_line
    FOR EACH ROW EXECUTE FUNCTION trg_block_modification();

-- ---------------------------------------------------------------------
-- ID03: Todo documento debe tener asiento cuadrado (débitos = créditos).
-- Se valida al COMMIT: si falla, se revierte toda la transacción.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_check_je_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_debit NUMERIC; v_credit NUMERIC; v_je BIGINT;
BEGIN
    v_je := COALESCE(NEW.je_id, OLD.je_id);
    SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
      INTO v_debit, v_credit
      FROM journal_entry_line WHERE je_id = v_je;
    IF v_debit <> v_credit OR v_debit = 0 THEN
        RAISE EXCEPTION 'JournalEntryUnbalanced: asiento % descuadrado (D=% C=%)', v_je, v_debit, v_credit
              USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_je_balanced
    AFTER INSERT ON journal_entry
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_je_balanced();

-- Cada documento de inventario debe traer al menos una línea (deferred)
CREATE OR REPLACE FUNCTION trg_check_doc_has_lines() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM inventory_doc_line WHERE doc_id = NEW.doc_id) THEN
        RAISE EXCEPTION 'EmptyDocument: el documento % no tiene líneas', NEW.doc_id
              USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_doc_has_lines
    AFTER INSERT ON inventory_doc
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_doc_has_lines();

-- ---------------------------------------------------------------------
-- ID02: Patrón de bloqueo para salidas (se usa desde el servicio).
-- Ejemplo de uso dentro de la transacción de la aplicación:
--
--   SELECT stock_id, on_hand
--   FROM item_stock
--   WHERE item_code = $1 AND warehouse_id = $2
--   FOR UPDATE;                -- el 2.º usuario espera aquí
--
-- El CHECK (on_hand >= 0) actúa como red de seguridad final: aunque la
-- aplicación fallara, nunca se podrá descontar más stock del existente.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Permisos recomendados (RN03 a nivel de rol)
-- ---------------------------------------------------------------------
-- CREATE ROLE erp_app LOGIN PASSWORD '...';
-- GRANT USAGE ON SCHEMA erp TO erp_app;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA erp TO erp_app;
-- REVOKE UPDATE, DELETE ON inventory_doc_line, inventory_doc_line_serial,
--        journal_entry, journal_entry_line FROM erp_app;
-- REVOKE DELETE ON inventory_doc FROM erp_app;
-- GRANT UPDATE (status) ON inventory_doc TO erp_app;   -- solo para cancelar
-- GRANT USAGE ON ALL SEQUENCES IN SCHEMA erp TO erp_app;
