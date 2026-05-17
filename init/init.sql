CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    price DECIMAL(10, 2) NOT NULL CHECK (price >= 0)
);

CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    order_date DATE NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO users (name, email) VALUES
('Alice Johnson', 'alice@example.com'),
('Bob Smith', 'bob@example.com'),
('Carol White', 'carol@example.com'),
('David Brown', 'david@example.com');

INSERT INTO products (title, price) VALUES
('Laptop', 1200.00),
('Mouse', 25.50),
('Keyboard', 45.99),
('Monitor', 320.00);

INSERT INTO orders (user_id, product_id, quantity, order_date) VALUES
(1, 1, 1, '2026-04-01'),
(1, 2, 2, '2026-04-02'),
(2, 3, 1, '2026-04-03'),
(3, 1, 1, '2026-04-04'),
(3, 4, 2, '2026-04-05'),
(4, 2, 3, '2026-04-06');

