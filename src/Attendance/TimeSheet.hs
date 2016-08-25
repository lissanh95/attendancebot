{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | This module contains functionality for analysing user check-ins. Only
-- the first check-in of the day is recorded, and times are represented in
-- the local time zone. cf. Attendance.CheckIn.
module Attendance.TimeSheet
    ( TimeSheet
    , newTimeSheet
    , updateTimeSheet

    , TimeSheetUpdate(..)
    , timeSheetUpdate

    , Timing(..)
    , lookupTiming

    , summaryOfDay
    , makeChart
    , lateComers
    , goodRunLength

    , today
    , yesterday
    , getMonday
    , getThisWeek
    ) where

import Control.Lens
import Control.Monad
import Data.AffineSpace
import qualified Data.HashMap.Strict as HMS
import Data.Hashable
import Data.List
import Data.Monoid
import qualified Data.Text as T
import Data.Thyme
import Data.Thyme.Calendar.WeekDate
import Graphics.Rendering.Chart.Backend.Cairo
import Graphics.Rendering.Chart.Easy
import System.Locale
import Web.Slack hiding (lines)

-------------------------------------------------------------------------------

data TimeSheetUpdate
    = CheckIn UserId UTCTime
    | MarkInactive UserId UTCTime -- ^ The user is inactive as of the specified time
    | MarkActive UserId UTCTime -- ^ The user is active as of the specified time

instance Show TimeSheetUpdate where
    show entry = case entry of
        CheckIn  uid ts -> showUidTs "Check-in" uid ts
        MarkInactive uid ts -> showUidTs "Inactive" uid ts
        MarkActive   uid ts -> showUidTs "Active" uid ts
      where
        showUidTs name (Id uid) ts = unwords
            [ name <> ":", T.unpack uid, "at"
            , formatTime defaultTimeLocale "%H:%M" ts
            ]

timeSheetUpdate :: Prism' T.Text TimeSheetUpdate
timeSheetUpdate = prism' pp parse
  where
    pp entry = case entry of
        (CheckIn  (Id uid) ts)  -> "checkin\t" <> review posixTime ts <> "\t" <> uid
        (MarkActive   (Id uid) ts)   -> "active\t" <> review posixTime ts <> "\t" <> uid
        (MarkInactive (Id uid) ts) -> "inactive\t" <> review posixTime ts <> "\t" <> uid
    parse txt = case T.splitOn "\t" txt of
        [x,y,z] | x == "checkin"  -> CheckIn  (Id z) <$> preview posixTime y
        [x,y,z] | x == "active"   -> MarkActive   (Id z) <$> preview posixTime y
        [x,y,z] | x == "inactive" -> MarkInactive (Id z) <$> preview posixTime y
        _ -> Nothing

posixTime :: Prism' T.Text UTCTime
posixTime = prism' pp parse
  where
    pp = T.pack . formatTime defaultTimeLocale "%s"
    parse = parseTime defaultTimeLocale "%s" . T.unpack

-------------------------------------------------------------------------------

-- | A closed or right-open interval over days. Bounds are inclusive.
data Holiday = CompletedHoliday Day Day | OngoingHoliday Day deriving (Eq)

startHoliday :: Day -> [Holiday] -> [Holiday]
startHoliday start hols = case hols of
    OngoingHoliday _ : _ -> hols
    _ -> OngoingHoliday start : hols

endHoliday :: Day -> [Holiday] -> [Holiday]
endHoliday end hols = case hols of
    OngoingHoliday start : xs -> CompletedHoliday start end : xs
    _ -> hols

-------------------------------------------------------------------------------

data TimeSheet = TimeSheet
    { _tsCheckIns :: HMS.HashMap (UserId, Day) TimeOfDay -- These times are local
    , _tsHolidays :: HMS.HashMap UserId [Holiday]
    , _tsTimeZone :: TimeZone
    }

-- TODO: Remove once liyang uploads the next version of thyme
instance Hashable Day

makeLenses ''TimeSheet

newTimeSheet :: IO TimeSheet
newTimeSheet = do
    _tsTimeZone <- getCurrentTimeZone
    let _tsCheckIns = HMS.empty
    let _tsHolidays = HMS.empty
    return TimeSheet{..}

updateTimeSheet :: TimeSheetUpdate -> TimeSheet -> TimeSheet
updateTimeSheet entry ts = case entry of
    CheckIn uid time ->
        let LocalTime day tod = time ^. utcLocalTime (ts ^. tsTimeZone)
        in over tsCheckIns (HMS.insertWith min (uid, day) tod) ts
    MarkInactive uid time ->
        let LocalTime day _ = time ^. utcLocalTime (ts ^. tsTimeZone)
        in over (tsHolidays . at uid . non []) (startHoliday (day .+^ 1)) ts
    MarkActive uid time ->
        let LocalTime day _ = time ^. utcLocalTime (ts ^. tsTimeZone)
        in over (tsHolidays . at uid . non []) (endHoliday day) ts

-------------------------------------------------------------------------------

data Timing
    = OnTime TimeOfDay
    | Late TimeOfDay
    | Absent
    | OnHoliday
    deriving (Eq, Ord, Show)

isOnTime, isLate :: Timing -> Bool
isOnTime = \case OnTime _ -> True; _ -> False
isLate   = \case Late   _ -> True; _ -> False
-- isAbsent = \case Absent   -> True; _ -> False

lookupTiming :: TimeSheet -> UserId -> Day -> Timing
lookupTiming ts uid day =
    case HMS.lookup (uid, day) (ts ^. tsCheckIns) of
        Just tod
            | tod < nineOClock -> OnTime tod
            | otherwise        -> Late tod
        Nothing                -> Absent
  where
    nineOClock :: TimeOfDay
    nineOClock = TimeOfDay 9 0 (fromSeconds' 0)

allUsers :: TimeSheet -> [UserId]
allUsers = nub . map fst . HMS.keys . view tsCheckIns

-------------------------------------------------------------------------------

-- userHistory :: UserId -> TimeSheet -> HMS.HashMap Day TimeOfDay
-- userHistory target timeSheet =
--     mapKeys snd $ HMS.filterWithKey (\(uid,_) _ -> uid == target) timeSheet

-- todaysCheckIns :: TimeSheet -> IO (HMS.HashMap UserId TimeOfDay)
-- todaysCheckIns timeSheet = do
--     today <- localDay . zonedTimeToLocalTime <$> getZonedTime
--     return $ mapKeys fst $ HMS.filterWithKey (\(_,day) _ -> day == today) timeSheet

summaryOfDay :: TimeSheet -> Day -> (PlotIndex, [Int])
summaryOfDay ts day =
    (PlotIndex (fromEnum day), [onTime, late])
  where
    checkins = map (\uid -> lookupTiming ts uid day) (allUsers ts)
    onTime = length $ filter isOnTime checkins
    late   = length $ filter isLate   checkins

makeChart :: TimeSheet -> FilePath -> IO ()
makeChart ts outpath = do
    recentDays <- take 20 . pastWeekDays <$> today
    let dataset = map (summaryOfDay ts) recentDays
    let chart = def
          & plot_bars_titles .~ ["On time","Late"]
          & plot_bars_style .~ BarsStacked
          & plot_bars_values .~ dataset
    let layout = def & layout_plots .~ [ plotBars chart ]
    let fileOpts = FileOptions{ _fo_size = (400,150), _fo_format = PNG }
    void $ renderableToFile fileOpts outpath (layoutToRenderable layout)

goodRunLength :: TimeSheet -> Day -> Int
goodRunLength ts start =
    let isGood = null . lateComers ts
    in length $ takeWhile isGood $ map (start .-^) [0..]

lateComers :: TimeSheet -> Day -> [UserId]
lateComers ts day =
    let late uid = case lookupTiming ts uid day of OnTime _ -> False; _ -> True
    in filter late (allUsers ts)

-------------------------------------------------------------------------------

-- | The weekdays (excluding the weekend) of the current week.
getThisWeek :: IO [Day]
getThisWeek = do
    x <- view weekDate <$> today
    return $ map (\day -> review weekDate x{ wdDay = day }) [1..5]

-- getThisMonth :: IO [Day]
-- getThisMonth = fmap (view weekDate) today <&> \WeekDate{..} ->
--     [ review weekDate (WeekDate wdYear w d)
--     | w <- map (\i -> wdWeek - i) [0,1,2], d <- [1..5]
--     ]

-- | The monday of the current week
getMonday :: IO Day
getMonday = do
    x <- view weekDate <$> today
    return $ review weekDate x{ wdDay = 1 }

today :: IO Day
today = localDay . zonedTimeToLocalTime <$> getZonedTime

yesterday :: IO Day
yesterday = head . drop 1 . pastWeekDays <$> today

-- | An infinite list of weekdays, in reverse order, starting from the
-- given day and working backwards (inclusive).
pastWeekDays :: Day -> [Day]
pastWeekDays d = map (d .-^ ) [0..]   -- FIXME

-------------------------------------------------------------------------------

-- mapKeys :: (Eq k2, Hashable k2) => (k1 -> k2) -> HMS.HashMap k1 v -> HMS.HashMap k2 v
-- mapKeys f = HMS.fromList . map (\(k,v) -> (f k,v)) . HMS.toList
