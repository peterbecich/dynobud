{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}
{-# Language DeriveGeneric #-}
{-# Language PolyKinds #-}

module Dyno.DirectCollocation.Dynamic
       ( DynPlotPoints
       , CollTrajMeta(..)
       , addCollocationChannel
       , MetaProxy(..)
       , toMeta
       , dynPlotPoints
       , catDynPlotPoints
       , NameTree(..)
       ) where

import GHC.Generics ( Generic )

import Data.Proxy ( Proxy(..) )
import Data.List ( mapAccumL )
import Data.Tree ( Tree(..) )
import Data.Vector.Cereal ()
import Data.Vector.Binary ()
import Data.Vector ( Vector )
import qualified Data.Vector as V
import qualified Data.Foldable as F
import qualified Data.Traversable as T
import qualified Data.Tree as Tree
import Data.Binary ( Binary )
import Data.Serialize ( Serialize )
import Linear.V

import Accessors ( AccessorTree(..), Lookup(..), accessors )
import PlotHo ( Plotter, addChannel )

import Dyno.View.Unsafe.View ( unJ, unJ' )

import Dyno.Vectorize ( Vectorize, Id(..), fill )
import Dyno.View.JV ( JV, splitJV )
import Dyno.View.View ( View(..), J )
import Dyno.View.JVec ( JVec(..) )
import qualified Dyno.TypeVecs as TV
import Dyno.TypeVecs ( Vec )
import Dyno.DirectCollocation.Types
import Dyno.DirectCollocation.Quadratures ( QuadratureRoots, mkTaus )

addCollocationChannel ::
  String -> (((DynPlotPoints Double, CollTrajMeta) -> IO ()) -> IO ()) -> Plotter ()
addCollocationChannel name action = addChannel name sameMeta toSignalTree action
  where
    toSignalTree ::
      (DynPlotPoints Double, CollTrajMeta)
      -> [Tree ( String
               , String
               , Maybe ((DynPlotPoints Double, CollTrajMeta) -> [[(Double, Double)]])
               )]
    toSignalTree = forestFromMeta . snd

sameMeta :: (DynPlotPoints Double, CollTrajMeta)
            -> (DynPlotPoints Double, CollTrajMeta)
            -> Bool
sameMeta (_,ctm0) (_,ctm1) =
  and [ ctmX ctm0 == ctmX ctm1
      , ctmZ ctm0 == ctmZ ctm1
      , ctmU ctm0 == ctmU ctm1
      , ctmP ctm0 == ctmP ctm1
      , ctmO ctm0 == ctmO ctm1
      , ctmQ ctm0 == ctmQ ctm1
      ]

data DynPlotPoints a = DynPlotPoints
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                     deriving Generic


--instance Binary a => Binary (DynPlotPoints a) -- binary is slower than serial by 2x on this
instance Serialize a => Serialize (DynPlotPoints a)

catDynPlotPoints :: V.Vector (DynPlotPoints a) -> DynPlotPoints a
catDynPlotPoints pps =
  DynPlotPoints
  (V.concatMap (\(DynPlotPoints x _ _ _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ x _ _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ x _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ x _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ _ x _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ _ _ x) -> x) pps)


dynPlotPoints ::
  forall x z u p h o q n deg a .
  ( Dim n, Dim deg, Real a, Fractional a, Show a
  , Vectorize x, Vectorize z, Vectorize u, Vectorize o, Vectorize p, Vectorize h
  )
  => QuadratureRoots
  -> CollTraj x z u p n deg (Vector a)
  -> Vec n (StageOutputs x o h q deg a)
  -> DynPlotPoints a
dynPlotPoints quadratureRoots (CollTraj tf' _ stages' xf) outputs
  -- if degree is one, each arc will be 1 point and won't get drawn
  -- see https://github.com/ghorn/dynobud/issues/72
  --     https://github.com/ghorn/Plot-ho-matic/issues/10
  --     https://github.com/timbod7/haskell-chart/issues/81
  | reflectDim (Proxy :: Proxy deg) == 1 =
                DynPlotPoints xss' (singleArc zss) (singleArc uss) (singleArc oss) (singleArc xdss) (singleArc hss)
  | otherwise = DynPlotPoints xss' zss uss oss xdss hss
  where
    singleArc :: Vector (Vector b) -> Vector (Vector b)
    singleArc = V.singleton . V.concat . V.toList
    nStages = size (Proxy :: Proxy (JVec n (JV Id)))
    tf,h :: a
    Id tf = splitJV tf'
    h = tf / fromIntegral nStages

    taus :: Vec deg a
    taus = mkTaus quadratureRoots

    stages :: Vec n (CollStage (JV x) (JV z) (JV u) deg (Vector a))
    stages = fmap split (unJVec (split stages'))

    xss' = xss `V.snoc` (V.singleton (tf, unJ xf))

    xss,zss,uss,oss,xdss,hss :: Vector (Vector (a, Vector a))
    (xss,zss,uss,oss,xdss,hss) = V.unzip6 xzuoxdhs

    -- todo: check this final time tf'' against expected tf
    (_tf'', xzuoxdhs) = T.mapAccumL f 0 $ V.zip (TV.unVec stages) (TV.unVec outputs)


    f :: a
         -> ( CollStage (JV x) (JV z) (JV u) deg (Vector a)
            , StageOutputs x o h q deg a
            )
         -> ( a
            , ( V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              )
            )
    f t0 (CollStage x0 xzus', stageOutputs) = (tnext, (xs,zs,us,os,xds,hs))
      where
        tnext = t0 + h
        xzus0 = fmap split (unJVec (split xzus')) :: Vec deg (CollPoint (JV x) (JV z) (JV u) (Vector a))

        xs :: V.Vector (a, V.Vector a)
        xs = (t0, unJ x0) `V.cons` xs' `V.snoc` (tnext, unJ (soXNext stageOutputs))

        xs',zs,us,os,xds,hs :: Vector (a, Vector a)
        (xs',zs,us,os,xds,hs) = V.unzip6 $ TV.unVec $ TV.tvzipWith3 g xzus0 (soVec stageOutputs) taus

        g :: CollPoint
             (JV x) (JV z) (JV u) (Vector a)
             -> (J (JV o) (Vector a), J (JV x) (Vector a), J (JV h) (Vector a))
             -> a
             -> ( (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                )
        g (CollPoint x z u) (o,x',pathc) tau =
          ( (t,unJ' "x" x)
          , (t,unJ' "z" z)
          , (t,unJ' "u" u)
          , (t,unJ' "o" o)
          , (t,unJ' "x'" x')
          , (t,unJ' "h" pathc)
          )
          where
            t = t0 + h*tau



data NameTree = NameTreeNode (String,String) [(String,NameTree)]
              | NameTreeLeaf Int
              deriving (Show, Eq, Generic)
instance Binary NameTree
instance Serialize NameTree

data CollTrajMeta = CollTrajMeta { ctmX :: NameTree
                                 , ctmZ :: NameTree
                                 , ctmU :: NameTree
                                 , ctmP :: NameTree
                                 , ctmO :: NameTree
                                 , ctmQ :: NameTree
                                 , ctmH :: NameTree
                                 } deriving (Eq, Generic, Show)
instance Binary CollTrajMeta
instance Serialize CollTrajMeta

namesFromAccTree :: AccessorTree a -> NameTree
namesFromAccTree x = (\(_,(_,y)) -> y) $ namesFromAccTree' 0 ("",x)

namesFromAccTree' :: Int -> (String, AccessorTree a) -> (Int, (String, NameTree))
namesFromAccTree' k (nm, ATGetter _) = (k+1, (nm, NameTreeLeaf k))
namesFromAccTree' k0 (nm, Data names ats) = (k, (nm, NameTreeNode names children))
  where
    (k, children) = mapAccumL namesFromAccTree' k0 ats


type MetaTree a = Tree.Forest (String, String, Maybe ((DynPlotPoints a, CollTrajMeta) -> [[(a,a)]]))

forestFromMeta :: CollTrajMeta -> MetaTree Double
forestFromMeta meta = [xTree,zTree,uTree,oTree,xdTree,hTree]
  where
    xTree  = blah (\(DynPlotPoints x _ _ _ _  _) ->  x) "differential states" (ctmX meta)
    zTree  = blah (\(DynPlotPoints _ z _ _ _  _) ->  z) "algebraic variables" (ctmZ meta)
    uTree  = blah (\(DynPlotPoints _ _ u _ _  _) ->  u) "controls" (ctmU meta)
    oTree  = blah (\(DynPlotPoints _ _ _ o _  _) ->  o) "outputs" (ctmO meta)
    xdTree = blah (\(DynPlotPoints _ _ _ _ xd _) -> xd) "diff state derivatives" (ctmX meta)
    hTree  = blah (\(DynPlotPoints _ _ _ _ _  h) ->  h) "path constraints" (ctmH meta)

    blah :: forall f c t
            . (Functor f, F.Foldable f)
            => (c -> f (f (t, Vector t))) -> String -> NameTree
            -> Tree (String, String, Maybe ((c,CollTrajMeta) -> [[(t, t)]]))
    blah f myname (NameTreeNode (nm1,_) children) =
      Tree.Node (myname,nm1,Nothing) $ map (uncurry (blah f)) children
    blah f myname (NameTreeLeaf k) = Tree.Node (myname,"",Just (woo . f . fst)) []
      where
        woo :: f (f (t, Vector t)) -> [[(t, t)]]
        woo = F.toList . fmap (F.toList . fmap (\(t,x) -> (t, x V.! k)))


data MetaProxy x z u p o q h = MetaProxy

toMeta :: forall x z u p o q h .
          ( Lookup (x ()), Lookup (z ()), Lookup (u ()), Lookup (p ()), Lookup (o ()), Lookup (q ())
          , Lookup (h ())
          , Vectorize x, Vectorize z, Vectorize u, Vectorize p, Vectorize o, Vectorize q
          , Vectorize h
          )
          => MetaProxy x z u p o q h -> CollTrajMeta
toMeta _ =
  CollTrajMeta
  { ctmX = namesFromAccTree $ accessors (fill () :: x ())
  , ctmZ = namesFromAccTree $ accessors (fill () :: z ())
  , ctmU = namesFromAccTree $ accessors (fill () :: u ())
  , ctmP = namesFromAccTree $ accessors (fill () :: p ())
  , ctmO = namesFromAccTree $ accessors (fill () :: o ())
  , ctmQ = namesFromAccTree $ accessors (fill () :: q ())
  , ctmH = namesFromAccTree $ accessors (fill () :: h ())
  }
