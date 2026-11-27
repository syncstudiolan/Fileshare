package com.sammyi57.pdftools

import org.junit.Assert.*
import org.junit.Test

class DscValidationFlowTest {
  @Test fun nativeVerdictRequiresAllChecksAndNeverOverridesRevocation() {
    for(mask in 0 until 64) {
      val b = (0..5).map { (mask and (1 shl it)) != 0 }
      assertEquals(mask == 31, DscVerdictPolicy.nativeVerified(b[0],b[1],b[2],b[3],b[4],b[5]))
    }
  }
  @Test fun onlyDocumentedEmudhraEvidenceHostsAllowed() {
    listOf("www.e-mudhra.com","e-mudhra.com","OCSP.E-MUDHRA.COM","cca.gov.in","ocvs.gov.in")
      .forEach { assertTrue(it,DscHttpPolicy.allowed(it)) }
    listOf("ocsp.e-mudhra.com.example.org","localhost","127.0.0.1","example.org","evil-e-mudhra.com")
      .forEach { assertFalse(it,DscHttpPolicy.allowed(it)) }
  }
}
