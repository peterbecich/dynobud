{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE InstanceSigs #-}

module Dyno.View.Internal.View
       ( View(..), J(..)
       , mkJ, mkJ', unJ, unJ'
       , JNone(..), JTuple(..), JTriple(..)
       , jfill
       , v2d, d2v, fromDMatrix
       , fmapJ, unzipJ
       ) where

import GHC.Generics hiding ( S )

import Data.Foldable ( Foldable )
import qualified Data.Foldable as F
import qualified Data.Sequence as Seq
import Data.Traversable ( Traversable )
import Data.Proxy ( Proxy(..) )
import Data.Vector ( Vector )
import qualified Data.Vector as V
import Data.Serialize ( Serialize(..) )

import qualified Casadi.DMatrix as DMatrix
import qualified Casadi.CMatrix as CM

import Dyno.View.Viewable ( Viewable(..) )
import Dyno.Vectorize ( Vectorize(..) )

data JTuple f g a = JTuple (J f a) (J g a) deriving ( Generic, Show )
instance (View f, View g) => View (JTuple f g)
data JTriple f g h a = JTriple (J f a) (J g a) (J h a) deriving ( Generic, Show )
instance (View f, View g, View h) => View (JTriple f g h)

newtype J (f :: * -> *) (a :: *) = UnsafeJ { unsafeUnJ :: a } deriving (Eq, Functor, Generic)

instance (View f, Viewable a, CM.CMatrix a) => Num (J f a) where
  (UnsafeJ x) + (UnsafeJ y) = mkJ (x + y)
  (UnsafeJ x) - (UnsafeJ y) = mkJ (x - y)
  (UnsafeJ x) * (UnsafeJ y) = mkJ (x * y)
  abs = fmap abs
  signum = fmap signum
  fromInteger k = mkJ (fromInteger k * CM.ones (n, 1))
    where
      n = size (Proxy :: Proxy f)

instance (View f, Viewable a, CM.CMatrix a) => Fractional (J f a) where
  (UnsafeJ x) / (UnsafeJ y) = mkJ (x / y)
  fromRational x = mkJ (fromRational x * CM.ones (n, 1))
    where
      n = size (Proxy :: Proxy f)

instance (View f, Viewable a, CM.CMatrix a) => Floating (J f a) where
  pi = mkJ (pi * CM.ones (n, 1))
    where
      n = size (Proxy :: Proxy f)
  (**) (UnsafeJ x) (UnsafeJ y) = mkJ (x ** y)
  exp   = fmap exp
  log   = fmap log
  sin   = fmap sin
  cos   = fmap cos
  tan   = fmap tan
  asin  = fmap asin
  atan  = fmap atan
  acos  = fmap acos
  sinh  = fmap sinh
  cosh  = fmap cosh
  tanh  = fmap tanh
  asinh = fmap asinh
  atanh = fmap atanh
  acosh = fmap acosh

mkJ :: forall f a . (View f, Viewable a) => a -> J f a
mkJ x = case mkJ' x of
  Right x' -> x'
  Left msg -> error msg

mkJ' :: forall f a . (View f, Viewable a) => a -> Either String (J f a)
mkJ' x
  | ny' == 1 && nx == nx' = Right (UnsafeJ x)
  | ny' == 0 && nx == nx' = Right (UnsafeJ (vrecoverDimension x 0))
  | otherwise = Left $ "mkJ length mismatch: typed size: " ++ show nx ++
                ", actual size: " ++ show nx'
  where
    nx = size (Proxy :: Proxy f)
    nx' = vsize1 x
    ny' = vsize2 x

unJ :: forall f a . (View f, Viewable a) => J f a -> a
unJ (UnsafeJ x)
  | nx == nx' = x
  | otherwise = error $ "unJ length mismatch: typed size: " ++ show nx ++
                ", actual size: " ++ show nx'
  where
    nx = size (Proxy :: Proxy f)
    nx' = vsize1 x

unJ' :: forall f a . (View f, Viewable a) => String -> J f a -> a
unJ' msg (UnsafeJ x)
  | nx == nx' = x
  | otherwise = error $ "unJ length mismatch in \"" ++ msg ++ "\": typed size: " ++ show nx ++
                ", actual size: " ++ show nx'
  where
    nx = size (Proxy :: Proxy f)
    nx' = vsize1 x

instance (Serialize a, View f) => Serialize (J f (Vector a)) where
  put = put . V.toList . unJ
  get = fmap (mkJ . V.fromList) get

instance Show a => Show (J f a) where
  showsPrec p (UnsafeJ x) = showsPrec p x

jfill :: forall a f . View f => a -> J f (Vector a)
jfill x = mkJ (V.replicate n x)
  where
    n = size (Proxy :: Proxy f)

fromDMatrix :: (CM.CMatrix a, Viewable a, View f) => J f DMatrix.DMatrix -> J f a
fromDMatrix = mkJ . CM.fromDMatrix . unJ

v2d :: View f => J f (V.Vector Double) -> J f DMatrix.DMatrix
v2d = mkJ . CM.fromDVector . unJ

d2v :: View f => J f DMatrix.DMatrix -> J f (V.Vector Double)
d2v = mkJ . DMatrix.ddata . CM.dense . unJ

fmapJ :: View f => (a -> b) -> J f (Vector a) -> J f (Vector b)
fmapJ f = mkJ . V.map f . unJ

unzipJ :: View f => J f (Vector (a,b)) -> (J f (Vector a), J f (Vector b))
unzipJ v = (mkJ x, mkJ y)
  where
    (x,y) = V.unzip (unJ v)

-- | view into a None, for convenience
data JNone a = JNone deriving ( Eq, Generic, Generic1, Show, Functor, Foldable, Traversable )
instance Vectorize JNone where
instance View JNone where

-- | Type-save "views" into vectors, which can access subvectors
--   without splitting then concatenating everything.
class View f where
  cat :: Viewable a => f a -> J f a
  default cat :: (GCat (Rep (f a)) a, Generic (f a), Viewable a) => f a -> J f a
  cat = mkJ . vveccat . V.fromList . F.toList . gcat . from

  size :: Proxy f -> Int
  default size :: (GSize (Rep (f ())), Generic (f ())) => Proxy f -> Int
  size = gsize . reproxy
    where
      reproxy :: Proxy g -> Proxy ((Rep (g ())) p)
      reproxy = const Proxy

  sizes :: Int -> Proxy f -> Seq.Seq Int
  default sizes :: (GSize (Rep (f ())), Generic (f ())) => Int -> Proxy f -> Seq.Seq Int
  sizes k0 = gsizes k0 . reproxy
    where
      reproxy :: Proxy g -> Proxy ((Rep (g ())) p)
      reproxy = const Proxy

  split :: Viewable a => J f a -> f a
  default split :: (GBuild (Rep (f a)) a, Generic (f a), Viewable a) => J f a -> f a
  split x'
    | null leftovers = to ret
    | otherwise = error $ unlines
                  [ "split got " ++ show (length leftovers) ++ " leftover fields"
                  , "ns: " ++ show ns ++ "\n" ++ show (map vsize1 leftovers)
                  --, "x: " ++ show x'
                  , "size1(x): " ++ show (vsize1 (unJ x'))
                  --, "leftovers: " ++ show leftovers
                  , "errors: " ++ show (reverse errors)
                  ]
    where
      x = unJ x'
      (ret,leftovers,errors) = gbuild [] xs
      xs = V.toList $ vvertsplit x (V.fromList ns)
      ns :: [Int]
      ns = (0 :) $ F.toList $ sizes 0 (Proxy :: Proxy f)

------------------------------------ SIZE ------------------------------
class GSize f where
  gsize :: Proxy (f p) -> Int
  gsizes :: Int -> Proxy (f p) -> Seq.Seq Int

instance (GSize f, GSize g) => GSize (f :*: g) where
  gsize pxy = gsize px + gsize py
    where
      reproxy :: Proxy ((x :*: y) p) -> (Proxy (x p), Proxy (y p))
      reproxy = const (Proxy,Proxy)
      (px, py) = reproxy pxy
  gsizes k0 pxy = xs Seq.>< ys
    where
      xs = gsizes k0 px
      ys = gsizes k1 py
      k1 = case Seq.viewr xs of
        Seq.EmptyR -> k0
        _ Seq.:> k1' -> k1'

      reproxy :: Proxy ((x :*: y) p) -> (Proxy (x p), Proxy (y p))
      reproxy = const (Proxy,Proxy)
      (px, py) = reproxy pxy
instance GSize f => GSize (M1 i d f) where
  gsize = gsize . reproxy
    where
      reproxy :: Proxy (M1 i d f p) -> Proxy (f p)
      reproxy _ = Proxy
  gsizes k0 = gsizes k0 . reproxy
    where
      reproxy :: Proxy (M1 i d f p) -> Proxy (f p)
      reproxy _ = Proxy

instance View f => GSize (Rec0 (J f a)) where
  gsize = size . reproxy
    where
      reproxy :: Proxy (Rec0 (J f a) p) -> Proxy f
      reproxy _ = Proxy
  gsizes k0 = Seq.singleton . (k0 +) . size . reproxy
    where
      reproxy :: Proxy (Rec0 (J f a) p) -> Proxy f
      reproxy _ = Proxy

instance GSize U1 where
  gsize = const 0
  gsizes = const . Seq.singleton

----------------------------- CAT -------------------------------
class GCat f a where
  gcat :: f p -> Seq.Seq a

-- concatenate fields recursively
instance (GCat f a, GCat g a) => GCat (f :*: g) a where
  gcat (x :*: y) = x' Seq.>< y'
    where
      x' = gcat x
      y' = gcat y
-- discard the metadata
instance GCat f a => GCat (M1 i d f) a where
  gcat = gcat . unM1

-- any field should just hold a view, no recursion here
instance (View f, Viewable a) => GCat (Rec0 (J f a)) a where
  gcat (K1 x) = Seq.singleton (unJ x)

instance GCat U1 a where
  gcat U1 = Seq.empty

-------------------------
class GBuild f a where
  gbuild :: [String] -> [a] -> (f p, [a], [String])

-- split fields recursively
instance (GBuild f a, GBuild g a, GSize f, GSize g) => GBuild (f :*: g) a where
  gbuild errs0 xs0 = (x :*: y, xs2, errs2)
    where
      (x,xs1,errs1) = gbuild errs0 xs0
      (y,xs2,errs2) = gbuild errs1 xs1

instance (GBuild f a, Datatype d) => GBuild (D1 d f) a where
  gbuild :: forall p . [String] -> [a] -> (D1 d f p, [a], [String])
  gbuild errs0 xs0 = (ret, xs1, errs1)
    where
      err = moduleName ret ++ "." ++ datatypeName ret :: String
      ret = M1 x :: D1 d f p
      (x,xs1,errs1) = gbuild (err:errs0) xs0

instance (GBuild f a, Constructor c) => GBuild (C1 c f) a where
  gbuild :: forall p . [String] -> [a] -> (C1 c f p, [a], [String])
  gbuild errs0 xs0 = (ret, xs1, errs1)
    where
      err = conName ret :: String
      ret = M1 x :: C1 c f p
      (x,xs1,errs1) = gbuild (err:errs0) xs0

instance (GBuild f a, Selector s) => GBuild (S1 s f) a where
  gbuild :: forall p . [String] -> [a] -> (S1 s f p, [a], [String])
  gbuild errs0 xs0 = (ret, xs1, errs1)
    where
      err = selName ret :: String
      ret = M1 x :: S1 s f p
      (x,xs1,errs1) = gbuild (err:errs0) xs0

-- any field should just hold a view, no recursion here
instance (View f, Viewable a) => GBuild (Rec0 (J f a)) a where
  gbuild errs (x:xs) = (K1 (mkJ x), xs, errs)
  gbuild errs [] = error $ "GBuild (Rec0 (J f a)) a: empty list" ++ show (reverse errs)

instance Viewable a => GBuild U1 a where
  gbuild errs (x:xs)
    | vsize1 x /= 0 = error $ "GBuild U1: got non-empty element: " ++
                      show (vsize1 x) ++ "\n" ++ show (reverse errs)
    | otherwise = (U1, xs, errs)
  gbuild errs [] = error $ "GBuild U1: got empty" ++ show (reverse errs)
