import { useEffect } from 'react'
import { useNavigate } from 'react-router'

export function SignupPage() {
  const navigate = useNavigate()

  useEffect(() => {
    navigate('/login', { replace: true })
  }, [navigate])

  return null
}
