{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}

module Dyno.DirectCollocation.Export
       ( toMatlab
       ) where

import Linear.V ( Dim(..) )
import Data.Vector ( Vector )
import qualified Data.Vector as V
import qualified Data.Foldable as F

import Dyno.Server.Accessors ( Lookup, flatten, accessors )
import Dyno.TypeVecs ( Vec )
import Dyno.Vectorize ( Vectorize, Proxy(..), fill )
import Dyno.View ( View(..), JV, JVec(..), unJ, splitJV )
import Dyno.DirectCollocation.Types ( CollTraj(..), CollStage(..), CollPoint(..) )
import Dyno.DirectCollocation.Quadratures ( timesFromTaus )

toMatlab ::
  forall x z u p n deg
  . ( Lookup (x Double), Vectorize x
    , Lookup (z Double), Vectorize z
    , Lookup (u Double), Vectorize u
    , Lookup (p Double), Vectorize p
    , Dim deg
    , Dim n
    )
  => Vec deg Double -> CollTraj x z u p n deg (Vector Double) -> String
toMatlab taus (CollTraj tf' p' stages' xf) = ret
  where
    tf = V.head (unJ tf')

    times :: Vec n (Double, Vec deg Double)
    times = timesFromTaus taus Proxy dt
      where
        dt = tf / fromIntegral (reflectDim (Proxy :: Proxy n) )

    xTimes = concatMap (\(t0,ts) -> t0 : F.toList ts) (F.toList times) ++ [tf]
    zuoTimes = concatMap (\(t0,ts) -> t0 : F.toList ts) (F.toList times) ++ [tf]

    stages :: [CollStage (JV x) (JV z) (JV u) deg (Vector Double)]
    stages = map split $ F.toList $ unJVec $ split stages'

    xs :: [x Double]
    xs = concatMap getXs stages ++ [splitJV xf]

    zs :: [z Double]
    zs = concatMap getZs stages

    us :: [u Double]
    us = concatMap getUs stages

    getXs (CollStage x0 xzus) = splitJV x0 : map (getX . split) (F.toList (unJVec (split xzus)))
    getZs (CollStage  _ xzus) =              map (getZ . split) (F.toList (unJVec (split xzus)))
    getUs (CollStage  _ xzus) =              map (getU . split) (F.toList (unJVec (split xzus)))

    getX :: CollPoint (JV x) (JV z) (JV u) (Vector Double) -> x Double
    getX (CollPoint x _ _) = splitJV x

    getZ :: CollPoint (JV x) (JV z) (JV u) (Vector Double) -> z Double
    getZ (CollPoint _ z _) = splitJV z

    getU :: CollPoint (JV x) (JV z) (JV u) (Vector Double) -> u Double
    getU (CollPoint _ _ u) = splitJV u

    atX :: [(String, x Double -> Double)]
    atX = flatten $ accessors (fill 0)

    atZ :: [(String, z Double -> Double)]
    atZ = flatten $ accessors (fill 0)

    atU :: [(String, u Double -> Double)]
    atU = flatten $ accessors (fill 0)

    atP :: [(String, p Double -> Double)]
    atP = flatten $ accessors (fill 0)

    p = splitJV p'

    woo :: String -> [xzu Double] -> String -> (xzu Double -> Double) -> String
    woo topName xzus name get = topName ++ "." ++ name ++ " = " ++ show (map get xzus) ++ ";"

    wooP :: String -> (p Double -> Double) -> String
    wooP name get = "params." ++ name ++ " = " ++ show (get p) ++ ";"

    ret :: String
    ret = init $ unlines $
          map (uncurry (woo "ret.diffStates" xs)) atX ++
          map (uncurry (woo "ret.algVars" zs)) atZ ++
          map (uncurry (woo "ret.controls" us)) atU ++
          map (uncurry wooP) atP ++
          [ ""
          , "ret.tx = " ++ show xTimes
          , "ret.tzuo = " ++ show zuoTimes
          ]