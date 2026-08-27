ALTER TABLE orders
    ADD COLUMN shipping_recipient_name VARCHAR(100) NULL AFTER total_amount,
    ADD COLUMN shipping_postal_code VARCHAR(8) NULL AFTER shipping_recipient_name,
    ADD COLUMN shipping_prefecture VARCHAR(50) NULL AFTER shipping_postal_code,
    ADD COLUMN shipping_city VARCHAR(100) NULL AFTER shipping_prefecture,
    ADD COLUMN shipping_address_line1 VARCHAR(200) NULL AFTER shipping_city,
    ADD COLUMN shipping_address_line2 VARCHAR(200) NULL AFTER shipping_address_line1,
    ADD COLUMN shipping_phone_number VARCHAR(20) NULL AFTER shipping_address_line2;
