{-# language BangPatterns           #-}
{-# language CPP                    #-}
{-# language DeriveFoldable         #-}
{-# language DeriveFunctor          #-}
{-# language DeriveTraversable      #-}
{-# language FlexibleContexts       #-}
{-# language FlexibleInstances      #-}
{-# language FunctionalDependencies #-}
{-# language MultiParamTypeClasses  #-}
{-# language Rank2Types             #-}
{-# language TemplateHaskell        #-}
-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Edward Kmett 2011-2019
-- License     :  BSD3
--
-- Maintainer  :  ekmett@gmail.com
-- Stability   :  experimental
-- Portability :  non-portable
--
-----------------------------------------------------------------------------
module Text.Trifecta.Parser
  ( Parser(..)
  , manyAccum
  -- * Feeding a parser more more input
  , Step(..)
  , feed
  , starve
  , stepParser
  , stepResult
  , stepIt
  -- * Parsing
  , runParser
  , parseFromFile
  , parseFromFileEx
  , parseString
  , parseText
  , parseTest
  ) where

import Control.Applicative as Alternative
import Control.Monad (MonadPlus(..), ap, join)
import Control.Monad.IO.Class
import qualified Control.Monad.Fail as Fail
import Data.Maybe (fromMaybe, isJust)
#if !(MIN_VERSION_base(4,11,0))
import Data.Semigroup
#endif
import Data.Semigroup.Reducer
import Data.Text as Strict hiding (empty, snoc)
import Data.Text.IO as TIO
import Data.Set as Set hiding (empty, toList)
import Prettyprinter as Pretty hiding (line)
import System.IO
import Text.Parser.Combinators
import Text.Parser.Char
import Text.Parser.LookAhead
import Text.Parser.Token
import Text.Trifecta.Combinators
import Text.Trifecta.Delta       as Delta
import Text.Trifecta.Rendering
import Text.Trifecta.Result
import Text.Trifecta.Rope
import Text.Trifecta.Util.It
import Text.Trifecta.Util.Pretty

-- | The type of a trifecta parser
--
-- The first four arguments are behavior continuations:
--
--   * epsilon success: the parser has consumed no input and has a result
--     as well as a possible Err; the position and chunk are unchanged
--     (see `pure`)
--
--   * epsilon failure: the parser has consumed no input and is failing
--     with the given Err; the position and chunk are unchanged (see
--     `empty`)
--
--   * committed success: the parser has consumed input and is yielding
--     the result, set of expected strings that would have permitted this
--     parse to continue, new position, and residual chunk to the
--     continuation.
--
--   * committed failure: the parser has consumed input and is failing with
--     a given ErrInfo (user-facing error message)
--
-- The remaining two arguments are
--
--   * the current position
--
--   * the chunk of input currently under analysis
--
-- `Parser` is an `Alternative`; trifecta's backtracking behavior encoded as
-- `<|>` is to behave as the leftmost parser which yields a value
-- (regardless of any input being consumed) or which consumes input and
-- fails.  That is, a choice of parsers will only yield an epsilon failure
-- if *all* parsers in the choice do.  If that is not the desired behavior,
-- see `try`, which turns a committed parser failure into an epsilon failure
-- (at the cost of error information).
newtype Parser a = Parser
  { unparser :: forall r.
       (a -> Err -> It Rope r)
    -> (Err -> It Rope r)
    -> (a -> Set String -> Delta -> Text -> It Rope r)  -- committed success
    -> (ErrInfo -> It Rope r)                                 -- committed err
    -> Delta
    -> Text
    -> It Rope r
  }

instance Functor Parser where
  fmap f (Parser m) = Parser $ \ eo ee co -> m (eo . f) ee (co . f)
  {-# inlinable fmap #-}
  a <$ Parser m = Parser $ \ eo ee co -> m (\_ -> eo a) ee (\_ -> co a)
  {-# inlinable (<$) #-}

instance Applicative Parser where
  pure a = Parser $ \ eo _ _ _ _ _ -> eo a mempty
  {-# inlinable pure #-}
  (<*>) = ap
  {-# inlinable (<*>) #-}

instance Alternative Parser where
  empty = Parser $ \_ ee _ _ _ _ -> ee mempty
  {-# inlinable empty #-}
  Parser m <|> Parser n = Parser $ \ eo ee co ce d bs ->
    m eo (\e -> n (\a e' -> eo a (e <> e')) (\e' -> ee (e <> e')) co ce d bs) co ce d bs
  {-# inlinable (<|>) #-}
  many p = Prelude.reverse <$> manyAccum (:) p
  {-# inlinable many #-}
  some p = (:) <$> p <*> Alternative.many p

instance Semigroup a => Semigroup (Parser a) where
  (<>) = liftA2 (<>)
  {-# inlinable (<>) #-}

instance (Semigroup a, Monoid a) => Monoid (Parser a) where
  mappend = (<>)
  {-# inlinable mappend #-}

  mempty = pure mempty
  {-# inlinable mempty #-}

instance Monad Parser where
  return = pure
  {-# inlinable return #-}
  Parser m >>= k = Parser $ \ eo ee co ce d bs ->
    m -- epsilon result: feed result to monadic continutaion; committed
      -- continuations as they were given to us; epsilon callbacks merge
      -- error information with `<>`
      (\a e -> unparser (k a) (\b e' -> eo b (e <> e')) (\e' -> ee (e <> e')) co ce d bs)
      -- epsilon error: as given
      ee
      -- committed result: feed result to monadic continuation and...
      (\a es d' bs' -> unparser (k a)
         -- epsilon results are now committed results due to m consuming.
         --
         -- epsilon success is now committed success at the new position
         -- (after m), yielding the result from (k a) and merging the
         -- expected sets (i.e. things that could have resulted in a longer
         -- parse)
         (\b e' -> co b (es <> _expected e') d' bs')
         -- epsilon failure is now a committed failure at the new position
         -- (after m); compute the error to display to the user
         (\e ->
           let errDoc = explain (renderingCaret d' bs') e { _expected = _expected e <> es }
               errDelta = _finalDeltas e
           in  ce $ ErrInfo errDoc (d' : errDelta)
         )
         -- committed behaviors as given; nothing exciting here
         co ce
         -- new position and remaining chunk after m
         d' bs')
      -- committed error, delta, and bytestring: as given
      ce d bs
  {-# inlinable (>>=) #-}
  (>>) = (*>)
  {-# inlinable (>>) #-}
#if !(MIN_VERSION_base(4,13,0))
  fail = Fail.fail
  {-# inlinable fail #-}
#endif

instance Fail.MonadFail Parser where
  fail s = Parser $ \ _ ee _ _ _ _ -> ee (failed s)
  {-# inlinable fail #-}

instance MonadPlus Parser where
  mzero = empty
  {-# inlinable mzero #-}
  mplus = (<|>)
  {-# inlinable mplus #-}

manyAccum :: (a -> [a] -> [a]) -> Parser a -> Parser [a]
manyAccum f (Parser p) = Parser $ \eo _ co ce d bs ->
  let walk xs x es d' bs' = p (manyErr d' bs') (\e -> co (f x xs) (_expected e <> es) d' bs') (walk (f x xs)) ce d' bs'
      manyErr d' bs' _ e  = ce (ErrInfo errDoc [d'])
        where errDoc = explain (renderingCaret d' bs') (e <> failed "'many' applied to a parser that accepted an empty string")
  in p (manyErr d bs) (eo []) (walk []) ce d bs

liftIt :: It Rope a -> Parser a
liftIt m = Parser $ \ eo _ _ _ _ _ -> do
  a <- m
  eo a mempty
{-# inlinable liftIt #-}

instance Parsing Parser where
  try (Parser m) = Parser $ \ eo ee co _ -> m eo ee co (\_ -> ee mempty)
  {-# inlinable try #-}
  Parser m <?> nm = Parser $ \ eo ee -> m
     (\a e -> eo a (if isJust (_reason e) then e { _expected = Set.singleton nm } else e))
     (\e -> ee e { _expected = Set.singleton nm })
  {-# inlinable (<?>) #-}
  skipMany p = () <$ manyAccum (\_ _ -> []) p
  {-# inlinable skipMany #-}
  unexpected s = Parser $ \ _ ee _ _ _ _ -> ee $ failed $ "unexpected " ++ s
  {-# inlinable unexpected #-}
  eof = notFollowedBy anyChar <?> "end of input"
  {-# inlinable eof #-}
  notFollowedBy p = try (optional p >>= maybe (pure ()) (unexpected . show))
  {-# inlinable notFollowedBy #-}

instance Errable Parser where
  raiseErr e = Parser $ \ _ ee _ _ _ _ -> ee e
  {-# inlinable raiseErr #-}

instance LookAheadParsing Parser where
  lookAhead (Parser m) = Parser $ \eo ee _ -> m eo ee (\a _ _ _ -> eo a mempty)
  {-# inlinable lookAhead #-}

instance CharParsing Parser where
  satisfy f = Parser $ \ _ ee co _ d bs ->
    case Strict.uncons $ Strict.drop (fromIntegral (columnByte d)) bs of
      Nothing        -> ee (failed "unexpected EOF")
      Just (c, xs)
        | not (f c)       -> ee mempty
        | Strict.null xs  -> let !ddc = d <> delta c
                             in join $ fillIt (co c mempty ddc (if c == '\n' then mempty else bs))
                                              (co c mempty)
                                              ddc
        | otherwise       -> co c mempty (d <> delta c) bs
  {-# inlinable satisfy #-}

instance TokenParsing Parser

instance DeltaParsing Parser where
  line = Parser $ \eo _ _ _ _ bs -> eo bs mempty
  {-# inlinable line #-}
  position = Parser $ \eo _ _ _ d _ -> eo d mempty
  {-# inlinable position #-}
  rend = Parser $ \eo _ _ _ d bs -> eo (rendered d bs) mempty
  {-# inlinable rend #-}
  slicedWith f p = do
    m <- position
    a <- p
    r <- position
    f a <$> liftIt (sliceIt m r)
  {-# inlinable slicedWith #-}

instance MarkParsing Delta Parser where
  mark = position
  {-# inlinable mark #-}
  release d' = Parser $ \_ ee co _ d bs -> do
    mbs <- rewindIt d'
    case mbs of
      Just bs' -> co () mempty d' bs'
      Nothing
        | bytes d' == bytes (rewind d) + fromIntegral (Strict.length bs) -> if near d d'
            then co () mempty d' bs
            else co () mempty d' mempty
        | otherwise -> ee mempty

-- | A 'Step' allows for incremental parsing, since the parser
--
--   - can be done with a final result
--   - have errored
--   - can have yielded a partial result with possibly more to come
data Step a
  = StepDone !Rope a
    -- ^ Parsing is done and has converted the 'Rope' to a final result

  | StepFail !Rope ErrInfo
    -- ^ Parsing the 'Rope' has failed with an error

  | StepCont !Rope (Result a) (Rope -> Step a)
    -- ^ The 'Rope' has been partially consumed and already yielded a 'Result',
    -- and if more input is provided, more results can be produced.
    --
    -- One common scenario for this is to parse log files: after parsing a
    -- single line, that data can already be worked with, but there may be more
    -- lines to come.

instance Show a => Show (Step a) where
  showsPrec d (StepDone r a) = showParen (d > 10) $
    showString "StepDone " . showsPrec 11 r . showChar ' ' . showsPrec 11 a
  showsPrec d (StepFail r xs) = showParen (d > 10) $
    showString "StepFail " . showsPrec 11 r . showChar ' ' . showsPrec 11 xs
  showsPrec d (StepCont r fin _) = showParen (d > 10) $
    showString "StepCont " . showsPrec 11 r . showChar ' ' . showsPrec 11 fin . showString " ..."

instance Functor Step where
  fmap f (StepDone r a)    = StepDone r (f a)
  fmap _ (StepFail r xs)   = StepFail r xs
  fmap f (StepCont r z k)  = StepCont r (fmap f z) (fmap f . k)

-- | Feed some additional input to a 'Step' to continue parsing a bit further.
feed :: Reducer t Rope => t -> Step r -> Step r
feed t (StepDone r a)    = StepDone (snoc r t) a
feed t (StepFail r xs)   = StepFail (snoc r t) xs
feed t (StepCont r _ k)  = k (snoc r t)
{-# inlinable feed #-}

-- | Assume all possible input has been given to the parser, execute it to yield
-- a final result.
starve :: Step a -> Result a
starve (StepDone _ a)    = Success a
starve (StepFail _ xs)   = Failure xs
starve (StepCont _ z _)  = z
{-# inlinable starve #-}

stepResult :: Rope -> Result a -> Step a
stepResult r (Success a)  = StepDone r a
stepResult r (Failure xs) = StepFail r xs
{-# inlinable stepResult #-}

stepIt :: It Rope a -> Step a
stepIt = go mempty where
  go r m = case simplifyIt m r of
    Pure a -> StepDone r a
    It a k -> StepCont r (pure a) $ \r' -> go r' (k r')
{-# inlinable stepIt #-}

data Stepping a
  = EO a Err
  | EE Err
  | CO a (Set String) Delta Text
  | CE ErrInfo

-- | Incremental parsing. A 'Step' can be supplied with new input using 'feed',
-- the final 'Result' is obtained using 'starve'.
stepParser
    :: Parser a
    -> Delta -- ^ Starting cursor position. Usually 'mempty' for the beginning of the file.
    -> Step a
stepParser (Parser p) d0 = joinStep $ stepIt $ do
  bs0 <- fromMaybe mempty <$> rewindIt d0
  go bs0 <$> p eo ee co ce d0 bs0
 where
  eo a e        = Pure (EO a e)
  ee e          = Pure (EE e)
  co a es d' bs = Pure (CO a es d' bs)
  ce errInf     = Pure (CE errInf)

  go :: Text -> Stepping a -> Result a
  go _   (EO a _)     = Success a
  go bs0 (EE e)       = Failure $
                          let errDoc = explain (renderingCaret d0 bs0) e
                          in  ErrInfo errDoc (d0 : _finalDeltas e)
  go _   (CO a _ _ _) = Success a
  go _   (CE e)       = Failure e

  joinStep :: Step (Result a) -> Step a
  joinStep (StepDone r (Success a)) = StepDone r a
  joinStep (StepDone r (Failure e)) = StepFail r e
  joinStep (StepFail r e)           = StepFail r e
  joinStep (StepCont r a k)         = StepCont r (join a) (joinStep <$> k)
  {-# inlinable joinStep #-}

-- | Run a 'Parser' on input that can be reduced to a 'Rope', e.g. 'String', or
-- 'ByteString'. See also the monomorphic versions 'parseString' and
-- 'parseByteString'.
runParser
    :: Reducer t Rope
    => Parser a
    -> Delta -- ^ Starting cursor position. Usually 'mempty' for the beginning of the file.
    -> t
    -> Result a
runParser p d bs = starve $ feed bs $ stepParser p d
{-# inlinable runParser #-}

-- | @('parseFromFile' p filePath)@ runs a parser @p@ on the input read from
-- @filePath@ using 'ByteString.readFile'. All diagnostic messages emitted over
-- the course of the parse attempt are shown to the user on the console.
--
-- > main = do
-- >   result <- parseFromFile numbers "digits.txt"
-- >   case result of
-- >     Nothing -> return ()
-- >     Just a  -> print $ sum a
parseFromFile :: MonadIO m => Parser a -> String -> m (Maybe a)
parseFromFile p fn = do
  result <- parseFromFileEx p fn
  case result of
   Success a  -> return (Just a)
   Failure xs -> do
     liftIO $ renderIO stdout $ renderPretty 0.8 80 $ (_errDoc xs) <> line'
     return Nothing

-- | @('parseFromFileEx' p filePath)@ runs a parser @p@ on the input read from
-- @filePath@ using 'ByteString.readFile'. Returns all diagnostic messages
-- emitted over the course of the parse and the answer if the parse was
-- successful.
--
-- > main = do
-- >   result <- parseFromFileEx (many number) "digits.txt"
-- >   case result of
-- >     Failure xs -> displayLn xs
-- >     Success a  -> print (sum a)
parseFromFileEx :: MonadIO m => Parser a -> String -> m (Result a)
parseFromFileEx p fn = do
  s <- liftIO $ TIO.readFile fn
  return $ parseText p (Directed (Strict.pack fn) 0 0 0 0) s

-- | Fully parse a 'UTF8.ByteString' to a 'Result'.
--
-- @parseByteString p delta i@ runs a parser @p@ on @i@.
parseText
    :: Parser a
    -> Delta -- ^ Starting cursor position. Usually 'mempty' for the beginning of the file.
    -> Text
    -> Result a
parseText = runParser

-- | Fully parse a 'String' to a 'Result'.
--
-- @parseByteString p delta i@ runs a parser @p@ on @i@.
parseString
    :: Parser a
    -> Delta -- ^ Starting cursor position. Usually 'mempty' for the beginning of the file.
    -> String
    -> Result a
parseString = runParser

parseTest :: (MonadIO m, Show a) => Parser a -> String -> m ()
parseTest p s = case parseText p mempty (Strict.pack s) of
  Failure xs -> liftIO $ renderIO stdout $ renderPretty 0.8 80 $ (_errDoc xs) <> line' -- TODO: retrieve columns
  Success a  -> liftIO (print a)
