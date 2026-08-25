package com.dennomuso.koeon

import android.app.Application
import com.dennomuso.koeon.core.session.IntercomSessionManager

class KoeonApplication : Application() {
    val intercomSession: IntercomSessionManager by lazy { IntercomSessionManager(this) }
}
