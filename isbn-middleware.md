# ISBN 缓存中间件 — 设计文档

## 数据库表 (PostgreSQL)

```sql
CREATE TABLE book_cache (
  id          SERIAL PRIMARY KEY,
  isbn        VARCHAR(20) UNIQUE NOT NULL,
  title       TEXT NOT NULL,
  author      TEXT,
  publisher   TEXT,
  publish_date TEXT,
  page_count  INTEGER,
  cover_url   TEXT,
  description TEXT,
  isbn_10     VARCHAR(20),
  isbn_13     VARCHAR(20),
  raw_data    JSONB,          -- 保留原始API返回，便于调试
  source      VARCHAR(20),    -- 'openlibrary' | 'google_books'
  created_at  TIMESTAMP DEFAULT NOW(),
  expires_at  TIMESTAMP DEFAULT (NOW() + INTERVAL '1 year')
);

CREATE INDEX idx_book_cache_isbn ON book_cache(isbn);
CREATE INDEX idx_book_cache_expires ON book_cache(expires_at);
```

## 完整代码 (Node.js + Express)

```javascript
// isbn-middleware.js
const express = require('express');
const { Pool } = require('pg');

const router = express.Router();
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

// ---------- helpers ----------

function normalizeIsbn(isbn) {
  const cleaned = isbn.replace(/[-\s]/g, '');
  if (cleaned.length === 10) return { isbn10: cleaned, isbn13: null };
  if (cleaned.length === 13) return { isbn13: cleaned, isbn10: null };
  // 尝试转成13位
  if (cleaned.length === 10) {
    const prefix = '978' + cleaned.slice(0, 9);
    let sum = 0;
    for (let i = 0; i < 12; i++) {
      sum += parseInt(prefix[i]) * (i % 2 === 0 ? 1 : 3);
    }
    const check = (10 - (sum % 10)) % 10;
    return { isbn10: cleaned, isbn13: prefix + check };
  }
  return null;
}

function mapOpenLibrary(data) {
  if (!data || data.error) return null;
  return {
    title: data.title || '未知书名',
    author: data.authors?.[0]?.name || data.by_statement || '',
    publisher: data.publishers?.[0]?.name || '',
    publish_date: data.publish_date || '',
    page_count: data.number_of_pages || null,
    cover_url: data.cover?.large || data.cover?.medium || '',
    description: typeof data.description === 'object'
      ? data.description.value
      : (data.description || ''),
    isbn_10: data.isbn_10?.[0] || '',
    isbn_13: data.isbn_13?.[0] || '',
    source: 'openlibrary',
  };
}

function mapGoogleBooks(data) {
  if (!data || !data.items?.[0]) return null;
  const v = data.items[0].volumeInfo;
  return {
    title: v.title || '未知书名',
    author: v.authors?.join(', ') || '',
    publisher: v.publisher || '',
    publish_date: v.publishedDate || '',
    page_count: v.pageCount || null,
    cover_url: v.imageLinks?.thumbnail?.replace('http:', 'https:') || '',
    description: v.description || '',
    isbn_10: v.industryIdentifiers?.find(i => i.type === 'ISBN_10')?.identifier || '',
    isbn_13: v.industryIdentifiers?.find(i => i.type === 'ISBN_13')?.identifier || '',
    source: 'google_books',
  };
}

// ---------- API 调用 ----------

async function fetchOpenLibrary(isbn13) {
  const url = `https://openlibrary.org/api/books?bibkeys=ISBN:${isbn13}&format=json&jscmd=data`;
  const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
  const json = await res.json();
  const raw = json[`ISBN:${isbn13}`];
  return raw ? mapOpenLibrary(raw) : null;
}

async function fetchGoogleBooks(isbn13, isbn10) {
  const query = isbn13 || isbn10;
  const url = `https://www.googleapis.com/books/v1/volumes?q=isbn:${query}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
  const json = await res.json();
  return mapGoogleBooks(json);
}

async function fetchWithFallback(isbn13, isbn10) {
  const promises = [
    fetchOpenLibrary(isbn13).catch(() => null),
    fetchGoogleBooks(isbn13, isbn10).catch(() => null),
  ];

  // 谁先返回就用谁
  const result = await Promise.race(promises);
  // 但也要等另一个完成（存入 raw_data 用）
  const all = await Promise.all(promises);
  const first = result || all[0] || all[1];
  const rawData = { openlibrary: all[0], google_books: all[1] };
  return first ? { ...first, raw_data: rawData } : null;
}

// ---------- 路由 ----------

router.get('/api/book/isbn/:isbn', async (req, res) => {
  const { isbn } = req.params;
  const normalized = normalizeIsbn(isbn);
  if (!normalized) {
    return res.status(400).json({ error: 'Invalid ISBN format' });
  }

  try {
    // 1. 查缓存
    const cacheQuery = await pool.query(
      `SELECT * FROM book_cache
       WHERE isbn = $1 AND expires_at > NOW()`,
      [normalized.isbn13 || normalized.isbn10]
    );

    if (cacheQuery.rows.length > 0) {
      const cached = cacheQuery.rows[0];
      return res.json({
        source: 'cache',
        data: {
          title: cached.title,
          author: cached.author,
          publisher: cached.publisher,
          publishDate: cached.publish_date,
          pageCount: cached.page_count,
          coverUrl: cached.cover_url,
          description: cached.description,
          isbn10: cached.isbn_10,
          isbn13: cached.isbn_13,
        },
      });
    }

    // 2. 缓存未命中，调 API
    const book = await fetchWithFallback(normalized.isbn13, normalized.isbn10);
    if (!book) {
      return res.status(404).json({ error: 'Book not found' });
    }

    // 3. 写入缓存
    await pool.query(
      `INSERT INTO book_cache
        (isbn, title, author, publisher, publish_date, page_count,
         cover_url, description, isbn_10, isbn_13, raw_data, source)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
       ON CONFLICT (isbn) DO UPDATE
         SET title = EXCLUDED.title, author = EXCLUDED.author,
             publisher = EXCLUDED.publisher, expires_at = NOW() + INTERVAL '1 year'`,
      [
        normalized.isbn13 || normalized.isbn10,
        book.title, book.author, book.publisher,
        book.publish_date, book.page_count,
        book.cover_url, book.description,
        book.isbn_10, book.isbn_13,
        JSON.stringify(book.raw_data),
        book.source,
      ]
    );

    return res.json({
      source: book.source,
      data: {
        title: book.title,
        author: book.author,
        publisher: book.publisher,
        publishDate: book.publish_date,
        pageCount: book.page_count,
        coverUrl: book.cover_url,
        description: book.description,
        isbn10: book.isbn_10,
        isbn13: book.isbn_13,
      },
    });

  } catch (err) {
    console.error('ISBN lookup error:', err.message);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
```

## 接入现有项目

```javascript
// server.js
const express = require('express');
const isbnRouter = require('./isbn-middleware');

const app = express();
app.use(express.json());
app.use(isbnRouter);  // 注册 /api/book/isbn/:isbn

app.listen(3000, () => {
  console.log('Server running on port 3000');
});
```

## 环境变量

```env
DATABASE_URL=postgresql://user:password@host:5432/bookdb
GOOGLE_BOOKS_API_KEY=your_key  # 可选，不设也能查到但有限额
```

## 关键设计点

| 项目 | 说明 |
|---|---|
| 缓存过期 | 1 年，常见的教材版本周期 |
| API 并发 | Promise.race + Promise.all —— race 返回最快的一个，all 存两个原始数据 |
| 超时控制 | AbortSignal.timeout(5000)，5 秒没响应就算失败 |
| 冲突处理 | ON CONFLICT DO UPDATE，同一 ISBN 重复查询自动覆盖 |
| ISBN 兼容 | 自动识别 10/13 位，去除连字符，10 位自动补成 13 位 |
