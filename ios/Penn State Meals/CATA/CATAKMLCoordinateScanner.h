#ifndef CATA_KML_COORDINATE_SCANNER_H
#define CATA_KML_COORDINATE_SCANNER_H
/* Header-only C11/C++ coordinate scanner. No Foundation, global locale changes,
   allocations, or per-tuple objects. Tuples may span any input chunk boundary.
   XML whitespace separates longitude,latitude[,altitude] tuples.
   Callers supply valid input storage and a non-null sink. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <math.h>

typedef enum {
    CATAKMLScanOK = 0,
    CATAKMLScanMalformedTuple,
    CATAKMLScanCoordinateOutOfRange,
    CATAKMLScanTupleTooLong,
    CATAKMLScanSinkRejected
} CATAKMLScanStatus;

typedef bool (*CATAKMLCoordinateSink)(void *context, double latitude, double longitude);
typedef struct {
    char tuple[192];
    size_t length;
    CATAKMLScanStatus status;
} CATAKMLCoordinateScanner;

static inline bool CATAKMLIsDigit(char c) { return c >= '0' && c <= '9'; }
static inline bool CATAKMLIsSpace(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

/* Deliberately accepts decimal notation only, not NaN, infinity or C hex floats.
   Long-double accumulation limits rounding error without a locale-dependent
   strtod call; the output remains double precision, as required by MapKit. */
static inline bool CATAKMLReadNumber(const char **cursor, const char *end, double *out) {
    const char *p = *cursor;
    bool negative = false;
    if (p < end && (*p == '-' || *p == '+')) { negative = *p == '-'; ++p; }
    bool digits = false;
    long double value = 0.0L;
    while (p < end && CATAKMLIsDigit(*p)) {
        digits = true;
        value = value * 10.0L + (long double)(*p++ - '0');
    }
    if (p < end && *p == '.') {
        ++p;
        long double place = 0.1L;
        while (p < end && CATAKMLIsDigit(*p)) {
            digits = true;
            value += (long double)(*p++ - '0') * place;
            place *= 0.1L;
        }
    }
    if (!digits) return false;
    if (p < end && (*p == 'e' || *p == 'E')) {
        ++p;
        bool expNegative = false;
        if (p < end && (*p == '-' || *p == '+')) { expNegative = *p == '-'; ++p; }
        if (p == end || !CATAKMLIsDigit(*p)) return false;
        unsigned exponent = 0;
        while (p < end && CATAKMLIsDigit(*p)) {
            if (exponent > 4096U) return false;
            exponent = exponent * 10U + (unsigned)(*p++ - '0');
        }
        if (exponent > 4096U) return false;
        if (value != 0.0L) value *= powl(10.0L, expNegative ? -(long double)exponent : (long double)exponent);
    }
    double result = (double)(negative ? -value : value);
    if (!isfinite(result)) return false;
    *out = result;
    *cursor = p;
    return true;
}

static inline CATAKMLScanStatus CATAKMLFlushTuple(CATAKMLCoordinateScanner *s,
                                               CATAKMLCoordinateSink sink, void *context) {
    if (s->status != CATAKMLScanOK || !s->length) return s->status;
    const char *p = s->tuple, *end = p + s->length;
    double longitude = 0.0, latitude = 0.0, altitude = 0.0;
    if (!CATAKMLReadNumber(&p, end, &longitude) || p == end || *p++ != ',' ||
        !CATAKMLReadNumber(&p, end, &latitude)) {
        return s->status = CATAKMLScanMalformedTuple;
    }
    if (p < end) {
        if (*p++ != ',' || !CATAKMLReadNumber(&p, end, &altitude)) {
            return s->status = CATAKMLScanMalformedTuple;
        }
    }
    if (p != end) return s->status = CATAKMLScanMalformedTuple;
    if (latitude < -90.0 || latitude > 90.0 || longitude < -180.0 || longitude > 180.0) {
        return s->status = CATAKMLScanCoordinateOutOfRange;
    }
    if (!sink(context, latitude, longitude)) return s->status = CATAKMLScanSinkRejected;
    s->length = 0;
    return s->status;
}

static inline CATAKMLScanStatus CATAKMLScanBytes(CATAKMLCoordinateScanner *s,
                                               const char *bytes, size_t length,
                                               CATAKMLCoordinateSink sink, void *context) {
    if (s->status != CATAKMLScanOK) return s->status;
    for (size_t i = 0; i < length; ++i) {
        char c = bytes[i];
        if (CATAKMLIsSpace(c)) {
            if (CATAKMLFlushTuple(s, sink, context) != CATAKMLScanOK) return s->status;
        } else {
            if (s->length == sizeof(s->tuple)) return s->status = CATAKMLScanTupleTooLong;
            s->tuple[s->length++] = c;
        }
    }
    return s->status;
}

/* NSString fallback: consume UTF-16 code units without creating a UTF-8
   string/buffer. Coordinates use ASCII syntax; non-ASCII input is an error.
   The caller can reuse a fixed stack buffer regardless of document size. */
static inline CATAKMLScanStatus CATAKMLScanUTF16(CATAKMLCoordinateScanner *s,
                                               const uint16_t *units, size_t length,
                                               CATAKMLCoordinateSink sink, void *context) {
    if (s->status != CATAKMLScanOK) return s->status;
    for (size_t i = 0; i < length; ++i) {
        if (units[i] > 127 || units[i] == 0) return s->status = CATAKMLScanMalformedTuple;
        char c = (char)units[i];
        if (CATAKMLIsSpace(c)) {
            if (CATAKMLFlushTuple(s, sink, context) != CATAKMLScanOK) return s->status;
        } else {
            if (s->length == sizeof(s->tuple)) return s->status = CATAKMLScanTupleTooLong;
            s->tuple[s->length++] = c;
        }
    }
    return s->status;
}

#endif
