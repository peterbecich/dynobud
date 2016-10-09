{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ConstraintKinds #-}

module Dyno.TypeVecs
       ( Vec(..)
       , mkVec'
       , tvlength
       , (|>)
       , (<|)
       , tvtranspose
       , tvzip
       , tvzip3
       , tvzip4
       , tvzipWith
       , tvzipWith3
       , tvzipWith4
       , tvzipWith5
       , tvzipWith6
       , tvunzip
       , tvunzip3
       , tvunzip4
       , tvunzip5
       , tvhead
       , tvtail
       , tvlast
       , tvshiftl
       , tvshiftr
       , tvlinspace
       , reifyVector
       , reifyDim
       , Dim, reflectDim
       )
       where

import GHC.Generics ( Generic, Generic1 )
import GHC.TypeLits

import Control.Applicative
import Data.Reflection ( reifyNat )
import qualified Data.Traversable as T
import qualified Data.Vector as V
import Data.Vector.Binary () -- instances
import qualified Data.Binary as B
import Linear ( Additive(..), Metric )
import Data.Proxy
import Data.Distributive ( Distributive(..) )
import Prelude -- BBP workaround

import Accessors ( Lookup(..), GAData(..), GAConstructor(..) )

import Dyno.View.Vectorize

-- for backwards compatability
type Dim = KnownNat
reflectDim :: Dim n => Proxy n -> Int
reflectDim = fromInteger . natVal

-- length-indexed vectors using phantom types
newtype Vec (n :: Nat) a = UnsafeVec {unVec :: V.Vector a}
                deriving (Functor, Foldable, Traversable, Eq, Ord, Generic, Generic1)
instance (Dim n, B.Binary a) => B.Binary (Vec n a) where
  put = B.put . unVec
  get = do
    x <- B.get
    case devectorize' x of
      Right y -> return y
      Left msg -> fail msg

instance (Lookup a, Dim n) => Lookup (Vec n a) where
  toAccessorTree lens0 = case n of
    -- if it's a vector of only 1, just ignore it
    1 -> toAccessorTree (lens0 . (lensK 0))
    _ -> Right $ GAData ("Vec " ++ show n) $ GAConstructor ("Vec " ++ show n) $ map child (take n [0..])
    where
      n = reflectDim (Proxy :: Proxy n)
      child k = (Just ("[" ++ show k ++ "]"), toAccessorTree (lens0 . lensK k))

      lensK k f (UnsafeVec v) = fmap (\vk -> devectorize (v V.// [(k,vk)])) (f vk0)
        where
          vk0 = v V.! k

instance Dim n => Distributive (Vec n) where
  distribute f = devectorize $ V.generate (reflectDim (Proxy :: Proxy n))
                 $ \i -> fmap (\v -> V.unsafeIndex (vectorize v) i) f
  {-# INLINE distribute #-}

instance Dim n => Applicative (Vec n) where
  pure x = ret
    where
      ret = UnsafeVec $ V.replicate (tvlength ret) x
  UnsafeVec xs <*> UnsafeVec ys = UnsafeVec $ V.zipWith id xs ys

instance Dim n => Additive (Vec n) where
  zero = pure 0
  UnsafeVec xs ^+^ UnsafeVec ys = UnsafeVec (V.zipWith (+) xs ys)
  UnsafeVec xs ^-^ UnsafeVec ys = UnsafeVec (V.zipWith (-) xs ys)

instance Dim n => Metric (Vec n)

instance Dim n => Vectorize (Vec n) where
  fill = pure
  vectorize = unVec
  devectorize' :: V.Vector a -> Either String (Vec n a)
  devectorize' x
    | n == n' = Right (UnsafeVec x)
    | otherwise = Left $ "mkVec: length mismatch, type-level: "
                  ++ show n ++ ", value-level: " ++ show n'
    where
      n = reflectDim (Proxy :: Proxy n)
      n' = V.length x
  vlength = const (reflectDim (Proxy :: Proxy n))

tvtranspose :: (Dim n, Dim m) => Vec n (Vec m a) -> Vec m (Vec n a)
tvtranspose = T.sequenceA

infixr 5 <|
infixl 5 |>
(<|) :: a -> Vec n a -> Vec (n + 1) a
(<|) x (UnsafeVec xs) = UnsafeVec $ V.cons x xs

(|>) :: Vec n a -> a -> Vec (n + 1) a
(|>) (UnsafeVec xs) x = UnsafeVec $ V.snoc xs x

mkVec' :: Dim n => [a] -> Vec n a
mkVec' = devectorize . V.fromList

tvlength :: forall n a. Dim n => Vec n a -> Int
tvlength = const $ reflectDim (Proxy :: Proxy n)

tvzip :: Dim n => Vec n a -> Vec n b -> Vec n (a,b)
tvzip x y = devectorize (V.zip (unVec x) (unVec y))

tvzip3 :: Dim n => Vec n a -> Vec n b -> Vec n c -> Vec n (a,b,c)
tvzip3 x y z = devectorize (V.zip3 (unVec x) (unVec y) (unVec z))

tvzip4 :: Dim n => Vec n a -> Vec n b -> Vec n c -> Vec n d -> Vec n (a,b,c,d)
tvzip4 x y z w = devectorize (V.zip4 (unVec x) (unVec y) (unVec z) (unVec w))

tvzipWith :: Dim n => (a -> b -> c) -> Vec n a -> Vec n b -> Vec n c
tvzipWith f x y = devectorize (V.zipWith f (unVec x) (unVec y))

tvzipWith3 :: Dim n => (a -> b -> c -> d) -> Vec n a -> Vec n b -> Vec n c -> Vec n d
tvzipWith3 f x y z = devectorize (V.zipWith3 f (unVec x) (unVec y) (unVec z))

tvzipWith4 :: Dim n => (a -> b -> c -> d -> e) -> Vec n a -> Vec n b -> Vec n c -> Vec n d -> Vec n e
tvzipWith4 f x y z u = devectorize (V.zipWith4 f (unVec x) (unVec y) (unVec z) (unVec u))

tvzipWith5 :: Dim n => (a -> b -> c -> d -> e -> f)
              -> Vec n a -> Vec n b -> Vec n c -> Vec n d -> Vec n e -> Vec n f
tvzipWith5 f x0 x1 x2 x3 x4 =
  devectorize (V.zipWith5 f (unVec x0) (unVec x1) (unVec x2) (unVec x3) (unVec x4))

tvzipWith6 :: Dim n => (a -> b -> c -> d -> e -> f -> g)
              -> Vec n a -> Vec n b -> Vec n c -> Vec n d -> Vec n e -> Vec n f -> Vec n g
tvzipWith6 f x0 x1 x2 x3 x4 x5 =
  devectorize (V.zipWith6 f (unVec x0) (unVec x1) (unVec x2) (unVec x3) (unVec x4) (unVec x5))





tvunzip :: Dim n => Vec n (a,b) -> (Vec n a, Vec n b)
tvunzip v = (devectorize v1, devectorize v2)
  where
    (v1,v2) = V.unzip (unVec v)

tvunzip3 :: Dim n => Vec n (a,b,c) -> (Vec n a, Vec n b, Vec n c)
tvunzip3 v = (devectorize v1, devectorize v2, devectorize v3)
  where
    (v1,v2,v3) = V.unzip3 (unVec v)

tvunzip4 :: Dim n => Vec n (a,b,c,d) -> (Vec n a, Vec n b, Vec n c, Vec n d)
tvunzip4 v = (devectorize v1, devectorize v2, devectorize v3, devectorize v4)
  where
    (v1,v2,v3,v4) = V.unzip4 (unVec v)

tvunzip5 :: Dim n => Vec n (a,b,c,d,e) -> (Vec n a, Vec n b, Vec n c, Vec n d, Vec n e)
tvunzip5 v = (devectorize v1, devectorize v2, devectorize v3, devectorize v4, devectorize v5)
  where
    (v1,v2,v3,v4,v5) = V.unzip5 (unVec v)

tvhead :: Dim n => Vec n a -> a
tvhead x = case V.length v of
  0 -> error "tvhead: empty"
  _ -> V.head v
  where
    v = unVec x

tvtail :: Dim n => Vec (n + 1) a -> Vec n a
tvtail x = case V.length v of
  0 -> error "tvtail: empty"
  _ -> devectorize $ V.tail v
  where
    v = unVec x

tvlast :: Dim n => Vec n a -> a
tvlast x = case V.length v of
  0 -> error "tvlast: empty"
  _ -> V.last v
  where
    v = unVec x

tvshiftl :: Dim n => Vec n a -> a -> Vec n a
tvshiftl xs x = devectorize $ V.tail (V.snoc (unVec xs) x)

tvshiftr :: Dim n => a -> Vec n a -> Vec n a
tvshiftr x xs = devectorize $ V.init (V.cons x (unVec xs))

instance Show a => Show (Vec n a) where
  showsPrec _ (UnsafeVec v) = showV (V.toList v)
    where
      showV []      = showString "<>"
      showV (x:xs)  = showChar '<' . shows x . showl xs
        where
          showl []      = showChar '>'
          showl (y:ys)  = showChar ',' . shows y . showl ys


reifyDim :: forall r.
            Int -> (forall (n :: Nat). KnownNat n => Proxy n -> r) -> r
reifyDim k f = reifyNat (fromIntegral k) f

reifyVector :: forall a r. V.Vector a -> (forall (n :: Nat). Dim n => Vec n a -> r) -> r
reifyVector v f = reifyDim (V.length v)
                  $ \(Proxy :: Proxy (n::Nat)) -> f (devectorize v :: Vec n a)
{-# INLINE reifyVector #-}

tvlinspace :: forall n a . (Dim n, Fractional a) => a -> a -> Vec n a
tvlinspace x0 xf = mkVec' [x0 + h * fromIntegral k  | k <- take n [(0::Int)..]]
  where
    n = reflectDim (Proxy :: Proxy n)
    h = (xf - x0) / fromIntegral (n - 1)
