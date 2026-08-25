package com.dennomuso.koeon.service

enum class ForegroundSessionMode { MICROPHONE_AND_MEDIA_PLAYBACK, MEDIA_PLAYBACK }

fun foregroundSessionMode(canPublish: Boolean): ForegroundSessionMode =
    if (canPublish) ForegroundSessionMode.MICROPHONE_AND_MEDIA_PLAYBACK else ForegroundSessionMode.MEDIA_PLAYBACK
