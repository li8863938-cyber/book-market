-- =====================================================
-- 泰皋阁 — Supabase RLS 策略
-- 在 Supabase Dashboard → SQL Editor 中运行
-- =====================================================

-- 1. books 表：任何人可查看在售书籍
DROP POLICY IF EXISTS "任何人都可查看在售书籍" ON books;
CREATE POLICY "任何人都可查看在售书籍"
  ON books FOR SELECT
  USING (true);

-- 2. books 表：登录用户可发布书籍
DROP POLICY IF EXISTS "登录用户可发布书籍" ON books;
CREATE POLICY "登录用户可发布书籍"
  ON books FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

-- 3. books 表：本人可更新自己的书籍
DROP POLICY IF EXISTS "本人可更新自己的书籍" ON books;
CREATE POLICY "本人可更新自己的书籍"
  ON books FOR UPDATE
  USING (auth.uid() = user_id);

-- 4. books 表：本人可删除自己的书籍
DROP POLICY IF EXISTS "本人可删除自己的书籍" ON books;
CREATE POLICY "本人可删除自己的书籍"
  ON books FOR DELETE
  USING (auth.uid() = user_id);

-- 5. orders 表：登录用户可下单
DROP POLICY IF EXISTS "登录用户可下单" ON orders;
CREATE POLICY "登录用户可下单"
  ON orders FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

-- 6. orders 表：买家或卖家可查看订单
DROP POLICY IF EXISTS "买家或卖家可查看订单" ON orders;
CREATE POLICY "买家或卖家可查看订单"
  ON orders FOR SELECT
  USING (auth.uid() = buyer_id OR auth.uid() = seller_id);
