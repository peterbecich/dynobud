{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PolyKinds #-}

module Dyno.DirectCollocation.Types
       ( CollTraj(..)
       , CollTraj'
       , CollStage(..)
       , CollPoint(..)
       , CollStageConstraints(..)
       , CollOcpConstraints'
       , CollOcpConstraints(..)
       , fillCollTraj
       , fillCollTraj'
       , fmapCollTraj
       , fmapCollTraj'
       , fmapStage
       , fmapStageJ
       , fmapCollPoint
       , fmapCollPointJ
       , fillCollConstraints
       , getXzus
       , getXzus'
         -- * for callbacks
       , Quadratures(..)
       , StageOutputs(..)
       , StageOutputs'
         -- * robust
       , CollTrajCov(..)
       , CollOcpCovConstraints(..)
       ) where

import GHC.Generics ( Generic, Generic1 )

import Linear.V ( Dim(..) )
import Data.Vector ( Vector )
import Data.Serialize ( Serialize )

import Accessors ( Lookup )

import Dyno.Ocp
import Dyno.View.Viewable ( Viewable )
import Dyno.View.View ( View(..), J, jfill )
import Dyno.View.JVec ( JVec(..), jreplicate )
import Dyno.View.Cov ( Cov )
import Dyno.View.JV ( JV, splitJV, catJV )
import Dyno.Vectorize ( Vectorize(..), Id )
import Dyno.TypeVecs ( Vec )


-- | CollTraj using type families to compress type parameters
type CollTraj' ocp n deg = CollTraj (X ocp) (Z ocp) (U ocp) (P ocp) n deg

-- design variables
data CollTraj x z u p n deg a =
  CollTraj
  { ctTf :: J (JV Id) a
  , ctP :: J (JV p) a
  , ctStages :: J (JVec n (CollStage (JV x) (JV z) (JV u) deg)) a
  , ctXf :: J (JV x) a
  } deriving (Eq, Generic, Show)

-- design variables
data CollTrajCov sx ocp n deg a =
  CollTrajCov (J (Cov (JV sx)) a) (J (CollTraj' ocp n deg) a)
  deriving (Eq, Generic, Show)

data CollStage x z u deg a =
  CollStage (J x a) (J (JVec deg (CollPoint x z u)) a)
  deriving (Eq, Generic, Show)

data CollPoint x z u a =
  CollPoint (J x a) (J z a) (J u a)
  deriving (Eq, Generic, Show)

-- constraints
data CollStageConstraints x deg r a =
  CollStageConstraints (J (JVec deg (JV r)) a) (J (JV x) a)
  deriving (Eq, Generic, Show)

-- | CollOcpConstraints using type families to compress type parameters
type CollOcpConstraints' ocp n deg = CollOcpConstraints (X ocp) (R ocp) (C ocp) (H ocp) n deg

data CollOcpConstraints x r c h n deg a =
  CollOcpConstraints
  { coCollPoints :: J (JVec n (JVec deg (JV r))) a
  , coContinuity :: J (JVec n (JV x)) a
  , coPathC :: J (JVec n (JVec deg (JV h))) a
  , coBc :: J (JV c) a
  } deriving (Eq, Generic, Show)

data CollOcpCovConstraints ocp n deg sh shr sc a =
  CollOcpCovConstraints
  { cocNormal :: J (CollOcpConstraints' ocp n deg ) a
  , cocCovPathC :: J (JVec n sh) a
  , cocCovRobustPathC :: J (JVec n (JV shr)) a
  , cocSbc :: J sc a
  } deriving (Eq, Generic, Show)

-- View instances
instance (View x, View z, View u) => View (CollPoint x z u)
instance (View x, View z, View u, Dim deg) => View (CollStage x z u deg)
instance ( Vectorize x, Vectorize z, Vectorize u, Vectorize p
         , Dim n, Dim deg
         ) =>  View (CollTraj x z u p n deg)
instance ( Vectorize (X ocp), Vectorize (Z ocp), Vectorize (U ocp), Vectorize (P ocp)
         , Vectorize sx
         , Dim n, Dim deg
         ) => View (CollTrajCov sx ocp n deg)

instance (Vectorize x, Vectorize r, Dim deg) => View (CollStageConstraints x deg r)
instance ( Vectorize x, Vectorize r, Vectorize c, Vectorize h
         , Dim n, Dim deg
         ) => View (CollOcpConstraints x r c h n deg)
instance ( Vectorize (X ocp), Vectorize (R ocp), Vectorize (C ocp), Vectorize (H ocp)
         , Dim n, Dim deg
         , View sh, Vectorize shr, View sc
         ) => View (CollOcpCovConstraints ocp n deg sh shr sc)


getXzus ::
  (Vectorize x, Vectorize z, Vectorize u, Dim n, Dim deg)
  => CollTraj x z u p n deg (Vector a)
  -> (Vec n (Vec deg (x a, z a, u a)))
getXzus traj = fmap snd $ fst $ getXzus' traj

getXzus' ::
  (Vectorize x, Vectorize z, Vectorize u, Dim n, Dim deg)
  => CollTraj x z u p n deg (Vector a)
  -> (Vec n (x a, Vec deg (x a, z a, u a)), x a)
getXzus' (CollTraj _ _ stages xf) =
  (fmap (getXzusFromStage . split) (unJVec (split stages)), splitJV xf)

getXzusFromStage :: (Vectorize x, Vectorize z, Vectorize u, Dim deg)
                    => CollStage (JV x) (JV z) (JV u) deg (Vector a)
                    -> (x a, Vec deg (x a, z a, u a))
getXzusFromStage (CollStage x0 xzus) = (splitJV x0, fmap (f . split) (unJVec (split xzus)))
  where
    f (CollPoint x z u) = (splitJV x, splitJV z, splitJV u)


fillCollConstraints ::
  forall x r c h n deg a .
  ( Vectorize x, Vectorize r, Vectorize c, Vectorize h
  , Dim n, Dim deg )
  => x a -> r a -> c a -> h a -> CollOcpConstraints x r c h n deg (Vector a)
fillCollConstraints x r c h =
  CollOcpConstraints
  { coCollPoints = jreplicate $ jreplicate $ catJV r
  , coContinuity = jreplicate $ catJV x
  , coPathC = jreplicate $ jreplicate $ catJV h
  , coBc = catJV c
  }


fillCollTraj ::
  forall x z u p n deg a .
  ( Vectorize x, Vectorize z, Vectorize u, Vectorize p
  , Dim n, Dim deg )
  => x a -> z a -> u a -> p a -> a
  -> CollTraj x z u p n deg (Vector a)
fillCollTraj x = fillCollTraj' x x

-- | first x argument fills the non-collocation points
fillCollTraj' ::
  forall x z u p n deg a .
  ( Vectorize x, Vectorize z, Vectorize u, Vectorize p
  , Dim n, Dim deg )
  => x a -> x a -> z a -> u a -> p a -> a
  -> CollTraj x z u p n deg (Vector a)
fillCollTraj' x' x z u p t =
  fmapCollTraj'
  (const x')
  (const x)
  (const z)
  (const u)
  (const p)
  (const t)
  (split (jfill () :: J (CollTraj x z u p n deg) (Vector ())))

fmapCollTraj ::
  forall x0 z0 u0 p0 x1 z1 u1 p1 n deg a b .
  ( Vectorize x0, Vectorize x1
  , Vectorize z0, Vectorize z1
  , Vectorize u0, Vectorize u1
  , Vectorize p0, Vectorize p1
  , Dim n, Dim deg )
  => (x0 a -> x1 b)
  -> (z0 a -> z1 b)
  -> (u0 a -> u1 b)
  -> (p0 a -> p1 b)
  -> (a -> b)
  -> CollTraj x0 z0 u0 p0 n deg (Vector a)
  -> CollTraj x1 z1 u1 p1 n deg (Vector b)
fmapCollTraj fx = fmapCollTraj' fx fx

-- | first x argument maps over the non-collocation points
fmapCollTraj' ::
  forall x0 z0 u0 p0 x1 z1 u1 p1 n deg a b .
  ( Vectorize x0, Vectorize x1
  , Vectorize z0, Vectorize z1
  , Vectorize u0, Vectorize u1
  , Vectorize p0, Vectorize p1
  , Dim n, Dim deg )
  => (x0 a -> x1 b)
  -> (x0 a -> x1 b)
  -> (z0 a -> z1 b)
  -> (u0 a -> u1 b)
  -> (p0 a -> p1 b)
  -> (a -> b)
  -> CollTraj x0 z0 u0 p0 n deg (Vector a)
  -> CollTraj x1 z1 u1 p1 n deg (Vector b)
fmapCollTraj' fx' fx fz fu fp ft (CollTraj tf1 p stages1 xf) =
  CollTraj tf2 (fj fp p) stages2 (fj fx' xf)
  where
    tf2 :: J (JV Id) (Vector b)
    tf2 = catJV $ fmap ft (splitJV tf1)
    stages2 = cat $ fmapJVec (fmapStage fx' fx fz fu) (split stages1)

    fj :: (Vectorize f1, Vectorize f2)
          => (f1 a -> f2 b)
          -> J (JV f1) (Vector a) -> J (JV f2) (Vector b)
    fj f = catJV . f . splitJV

fmapJVec :: (View f, View g, Viewable a, Viewable b)
            => (f a -> g b) -> JVec deg f a -> JVec deg g b
fmapJVec f = JVec . fmap (cat . f . split) . unJVec

fmapStage :: forall x1 x2 z1 z2 u1 u2 deg a b .
             ( Vectorize x1, Vectorize x2
             , Vectorize z1, Vectorize z2
             , Vectorize u1, Vectorize u2
             , Dim deg )
             => (x1 a -> x2 b)
             -> (x1 a -> x2 b)
             -> (z1 a -> z2 b)
             -> (u1 a -> u2 b)
             -> CollStage (JV x1) (JV z1) (JV u1) deg (Vector a)
             -> CollStage (JV x2) (JV z2) (JV u2) deg (Vector b)
fmapStage fx' fx fz fu = fmapStageJ (fj fx') (fj fx) (fj fz) (fj fu)
  where
    fj :: (Vectorize f1, Vectorize f2)
          => (f1 a -> f2 b)
          -> J (JV f1) (Vector a)
          -> J (JV f2) (Vector b)
    fj f = catJV . f . splitJV

fmapStageJ :: forall x1 x2 z1 z2 u1 u2 deg a b .
              ( Viewable a, Viewable b
              , View x1, View x2
              , View z1, View z2
              , View u1, View u2
              , Dim deg )
              => (J x1 a -> J x2 b)
              -> (J x1 a -> J x2 b)
              -> (J z1 a -> J z2 b)
              -> (J u1 a -> J u2 b)
              -> CollStage x1 z1 u1 deg a
              -> CollStage x2 z2 u2 deg b
fmapStageJ fx' fx fz fu (CollStage x0 points0) = CollStage (fx' x0) points1
  where
    points1 = cat $ fmapJVec (fmapCollPointJ fx fz fu) (split points0)

fmapCollPoint :: forall x1 x2 z1 z2 u1 u2 a b .
                 ( Vectorize x1, Vectorize x2
                 , Vectorize z1, Vectorize z2
                 , Vectorize u1, Vectorize u2 )
                 => (x1 a -> x2 b)
                 -> (z1 a -> z2 b)
                 -> (u1 a -> u2 b)
                 -> CollPoint (JV x1) (JV z1) (JV u1) (Vector a)
                 -> CollPoint (JV x2) (JV z2) (JV u2) (Vector b)
fmapCollPoint fx fz fu = fmapCollPointJ (fj fx) (fj fz) (fj fu)
  where
    fj :: (Vectorize f1, Vectorize f2)
          => (f1 a -> f2 b)
          -> J (JV f1) (Vector a)
          -> J (JV f2) (Vector b)
    fj f = catJV . f . splitJV

fmapCollPointJ :: forall x1 x2 z1 z2 u1 u2 a b .
                  ( View x1, View x2
                  , View z1, View z2
                  , View u1, View u2 )
                  => (J x1 a -> J x2 b)
                  -> (J z1 a -> J z2 b)
                  -> (J u1 a -> J u2 b)
                  -> CollPoint x1 z1 u1 a
                  -> CollPoint x2 z2 u2 b
fmapCollPointJ fx fz fu (CollPoint x z u) = CollPoint (fx x) (fz z) (fu u)

-- | for callbacks
data Quadratures q qo a =
  Quadratures
  { qLagrange :: a
  , qUser :: q a
  , qOutputs :: qo a
  } deriving (Functor, Generic, Generic1)
instance (Vectorize q, Vectorize qo) => Vectorize (Quadratures q qo)
instance (Lookup a, Lookup (q a), Lookup (qo a)) => Lookup (Quadratures q qo a)
instance (Serialize a, Serialize (q a), Serialize (qo a)) => Serialize (Quadratures q qo a)

-- | for callbacks
data StageOutputs x o h q qo po deg a =
  StageOutputs
  { soVec :: Vec deg ( J (JV o) (Vector a)
                     , J (JV x) (Vector a)
                     , J (JV h) (Vector a)
                     , J (JV po) (Vector a)
                     , Quadratures q qo a -- qs
                     , Quadratures q qo a -- qdots
                     )
  , soXNext :: J (JV x) (Vector a)
  , soQNext :: Quadratures q qo a
  } deriving Generic

type StageOutputs' ocp deg = StageOutputs (X ocp) (O ocp) (H ocp) (Q ocp) (QO ocp) (PO ocp) deg

instance ( Serialize a, Serialize (q a), Serialize (qo a)
         , Vectorize x, Vectorize o, Vectorize h, Vectorize po
         , Dim deg
         ) => (Serialize (StageOutputs x o h q qo po deg a))
