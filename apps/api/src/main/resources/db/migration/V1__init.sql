-- 스키마는 이미 ec로 접속하므로 테이블만 생성
CREATE TABLE IF NOT EXISTS products (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price BIGINT NOT NULL,
    image_url VARCHAR(512),
    description VARCHAR(1000)
) ENGINE=InnoDB DEFAULT CHARSET = utf8mb4;

INSERT INTO products (name, price, image_url, description)
VALUES ('Basic T-Shirt',19000,'https://picsum.photos/seed/tee/400','Soft cotton tee'),
       ('Canvas Tote',22000,'https://picsum.photos/seed/tote/400','Everyday tote bag'),
       ('Mug',12000,'https://picsum.photos/seed/mug/400','Ceramic mug');
